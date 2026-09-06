#!/usr/bin/env python3
"""Local, synthetic live TV fixture. No provider accounts or production media.

python3 Scripts/tvos_fixture_server.py --port 8765
Endpoints: /playlist.m3u, /guide.xml, /live.ts, /hls/live.m3u8
"""
import argparse
import datetime
import http.server
import pathlib
import shutil
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise SystemExit('Install FFmpeg on the development Mac to generate test media.')
    with tempfile.TemporaryDirectory(prefix='channeldeck-tv-fixture-') as temp:
        root = pathlib.Path(temp)
        sample = root / 'sample.ts'
        subprocess.run([ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=25',
                        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '20',
                        '-c:v', 'libx264', '-preset', 'ultrafast', '-b:v', '700k', '-g', '50',
                        '-c:a', 'aac', '-b:a', '96k', '-f', 'mpegts', str(sample)], check=True)
        format_first, format_second = root / 'format-first.ts', root / 'format-second.ts'
        subprocess.run([ffmpeg, '-v', 'error', '-i', str(sample), '-t', '8', '-c', 'copy',
                        '-muxrate', '2000000', '-f', 'mpegts', str(format_first)], check=True)
        subprocess.run([ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=25',
                        '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=48000', '-t', '20',
                        '-c:v', 'mpeg2video', '-b:v', '700k', '-g', '25', '-c:a', 'mp2', '-b:a', '192k',
                        '-output_ts_offset', '8', '-tables_version', '1', '-muxrate', '2000000',
                        '-f', 'mpegts', str(format_second)], check=True)
        hls = root / 'hls'
        hls.mkdir()
        process = subprocess.Popen([ffmpeg, '-v', 'error', '-re', '-stream_loop', '-1', '-i', str(sample),
                                    '-c', 'copy', '-f', 'hls', '-hls_time', '2', '-hls_list_size', '6',
                                    '-hls_flags', 'delete_segments+independent_segments', str(hls / 'live.m3u8')],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *positional, **keywords):
                super().__init__(*positional, directory=str(root), **keywords)

            def log_message(self, *unused):
                pass

            def document(self, body, mime):
                data = body.encode()
                self.send_response(200)
                self.send_header('Content-Type', mime)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                self.path = self.path.split('?', 1)[0]
                if self.path == '/format-change.ts':
                    self.send_response(200)
                    self.send_header('Content-Type', 'video/mp2t')
                    self.end_headers()
                    started, sent = time.monotonic(), 0
                    try:
                        for part in (format_first, format_second):
                            with part.open('rb') as source:
                                while block := source.read(188 * 32):
                                    self.wfile.write(block)
                                    self.wfile.flush()
                                    sent += len(block)
                                    time.sleep(max(0, started + sent * 8 / 2000000 - time.monotonic()))
                        time.sleep(5)
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return
                if self.path == '/playlist.m3u':
                    return self.document('#EXTM3U url-tvg="/guide.xml"\n'
                                         '#EXTINF:-1 tvg-id="synthetic" group-title="Test channels",Synthetic MPEG-TS\n/live.ts\n'
                                         '#EXTINF:-1 tvg-id="synthetic" group-title="Test channels",Synthetic HLS\n/hls/live.m3u8\n', 'audio/x-mpegurl')
                if self.path == '/large-playlist.m3u':
                    entries = ['#EXTM3U url-tvg="/guide.xml"']
                    for i in range(3200):
                        group = 'Test channels' if i < 500 else f'Group {1 + (i - 500) // 50:02d}'
                        name = 'Synthetic MPEG-TS' if i == 0 else f'Synthetic channel {i:04d}'
                        entries.extend([f'#EXTINF:-1 tvg-id="synthetic" group-title="{group}",{name}', f'/live.ts?channel={i}'])
                    return self.document('\n'.join(entries) + '\n', 'audio/x-mpegurl')
                if self.path == '/guide.xml':
                    now = datetime.datetime.now(datetime.timezone.utc).replace(minute=0, second=0, microsecond=0)
                    shows = ''.join(f'<programme channel="synthetic" start="{(now + datetime.timedelta(hours=i)).strftime("%Y%m%d%H%M%S %z")}" stop="{(now + datetime.timedelta(hours=i+1)).strftime("%Y%m%d%H%M%S %z")}"><title>Live playback test {i+1}</title><desc>Synthetic color patterns and audio generated on the development Mac.</desc></programme>' for i in range(8))
                    return self.document(f'<?xml version="1.0"?><tv>{shows}</tv>', 'application/xml')
                if self.path in ('/live.ts', '/disconnect.ts', '/fast.ts'):
                    self.send_response(200)
                    self.send_header('Content-Type', 'video/mp2t')
                    self.end_headers()
                    pacing = [] if self.path == '/fast.ts' else ['-re']
                    duration = ['-t', '660'] if self.path == '/fast.ts' else []
                    child = subprocess.Popen([ffmpeg, '-v', 'error', *pacing, '-stream_loop', '-1', '-i', str(sample),
                                              *duration, '-c', 'copy', '-f', 'mpegts', 'pipe:1'], stdout=subprocess.PIPE,
                                             stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    try:
                        started = time.monotonic()
                        while block := child.stdout.read(188 * 32):
                            self.wfile.write(block)
                            self.wfile.flush()
                            if self.path == '/disconnect.ts' and time.monotonic() - started > 7:
                                break
                        if self.path == '/fast.ts':
                            time.sleep(5)  # Leave time to inspect eviction before EOF/reconnection.
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    finally:
                        child.terminate()
                        child.wait(timeout=5)
                    return
                return super().do_GET()

        server = http.server.ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
        print(f'Synthetic TV fixture ready at http://127.0.0.1:{args.port}/playlist.m3u', flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()
            process.terminate()
            process.wait(timeout=5)


if __name__ == '__main__':
    main()
