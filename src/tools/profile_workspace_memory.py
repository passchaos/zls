#!/usr/bin/env python3
"""Measure a bounded Linux ZLS workspace lifecycle using copies of Zig sources."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time


class Client:
    def __init__(self, process, max_rss_mib):
        self.process = process
        self.limit_kib = max_rss_mib * 1024
        self.buffer = bytearray()
        self.sequence = 0
        self.samples = []
        self.observed_peak_kib = 0

    def sample(self, phase):
        status = Path(f"/proc/{self.process.pid}/status").read_text()
        fields = {line.split(':')[0]: line.split(':')[1].strip() for line in status.splitlines()}
        kib = lambda name: int(fields.get(name, '0 kB').split()[0])
        rss_kib = kib('VmRSS')
        kernel_peak_kib = kib('VmHWM')
        self.observed_peak_kib = max(self.observed_peak_kib, rss_kib, kernel_peak_kib)
        sample = dict(phase=phase, rss_kib=rss_kib,
                      observed_peak_kib=self.observed_peak_kib,
                      kernel_peak_kib=kernel_peak_kib,
                      anonymous_kib=kib('RssAnon'), file_kib=kib('RssFile'),
                      shared_kib=kib('RssShmem'), swap_kib=kib('VmSwap'),
                      virtual_kib=kib('VmSize'), threads=int(fields['Threads']))
        if self.observed_peak_kib > self.limit_kib:
            raise RuntimeError(f"ZLS exceeded the RSS limit: {sample}")
        return sample

    def checkpoint(self, phase):
        self.samples.append(self.sample(phase))

    def send(self, message):
        data = json.dumps(dict(jsonrpc='2.0', **message), ensure_ascii=False).encode()
        self.process.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
        self.process.stdin.flush()

    def notify(self, method, params):
        self.send(dict(method=method, params=params))

    def receive(self, deadline):
        while time.monotonic() < deadline:
            boundary = self.buffer.find(b'\r\n\r\n')
            if boundary >= 0:
                headers = dict(line.split(b':', 1) for line in bytes(self.buffer[:boundary]).split(b'\r\n'))
                size = int(headers[b'Content-Length'])
                end = boundary + 4 + size
                if len(self.buffer) >= end:
                    message = json.loads(self.buffer[boundary + 4:end])
                    del self.buffer[:end]
                    return message
            self.sample('waiting')
            ready, _, _ = select.select([self.process.stdout], [], [], 0.1)
            if ready:
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError('ZLS closed stdout before replying')
                self.buffer.extend(chunk)
        raise TimeoutError('LSP request exceeded 60 seconds')

    def request(self, method, params):
        self.sequence += 1
        sequence = self.sequence
        self.send(dict(id=sequence, method=method, params=params))
        deadline = time.monotonic() + 60
        while True:
            response = self.receive(deadline)
            if 'method' in response:
                if 'id' in response:
                    self.send(dict(id=response['id'], result=None))
                continue
            if response.get('id') != sequence:
                raise RuntimeError(f"Unexpected response: {response}")
            if 'error' in response:
                raise RuntimeError(response['error'])
            return response.get('result')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('sources', type=Path, nargs='+')
    parser.add_argument('--cycles', type=int, default=5)
    parser.add_argument('--rounds', type=int, default=20)
    parser.add_argument('--max-rss-mib', type=int, default=2048)
    args = parser.parse_args()
    if min(args.cycles, args.max_rss_mib) < 1 or args.rounds < 0:
        parser.error('cycles and max-rss-mib must be positive; rounds must be non-negative')
    sources = [(path.name, path.read_text()) for path in args.sources]
    with tempfile.TemporaryDirectory(prefix='zls-memory-') as directory:
        root = Path(directory)
        config = root / 'zls.json'
        config.write_text(json.dumps(dict(enable_build_on_save=False)))
        with (root / 'stderr.log').open('w+') as stderr:
            process = subprocess.Popen([str(args.binary.resolve()), '--config-path', str(config)],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
            client = Client(process, args.max_rss_mib)
            started = time.monotonic()
            checksums = {}
            latencies = {}
            phase_latencies = dict(open=[], query=[], close=[])
            try:
                result = client.request('initialize', dict(
                    processId=os.getpid(), rootUri=root.as_uri(),
                    workspaceFolders=[dict(uri=root.as_uri(), name='memory-profile')],
                    capabilities=dict(general=dict(positionEncodings=['utf-16']))))
                if result['capabilities']['positionEncoding'] != 'utf-16':
                    raise RuntimeError('UTF-16 negotiation failed')
                client.notify('initialized', {})
                client.request('workspace/symbol', dict(query=''))
                client.checkpoint('initialized')
                for cycle in range(args.cycles):
                    phase_started = time.monotonic_ns()
                    for index, (name, source) in enumerate(sources):
                        uri = (root / f'{index}-{name}').as_uri()
                        client.notify('textDocument/didOpen', dict(textDocument=dict(
                            uri=uri, languageId='zig', version=cycle + 1, text=source)))
                    client.request('workspace/symbol', dict(query=''))
                    phase_latencies['open'].append(time.monotonic_ns() - phase_started)
                    client.checkpoint(f'opened-{cycle}')
                    phase_started = time.monotonic_ns()
                    for _ in range(args.rounds):
                        for query in ('allocator', 'type', 'parse', '__zls_memory_missing__'):
                            before = time.monotonic_ns()
                            symbols = client.request('workspace/symbol', dict(query=query)) or []
                            latencies.setdefault(query, []).append(time.monotonic_ns() - before)
                            canonical = sorted((symbol['name'], symbol['kind'],
                                                Path(symbol['location']['uri']).name,
                                                json.dumps(symbol['location']['range'], sort_keys=True))
                                               for symbol in symbols)
                            checksum = hashlib.sha256(json.dumps(canonical).encode()).hexdigest()
                            value = dict(count=len(symbols), sha256=checksum)
                            if query in checksums and checksums[query] != value:
                                raise RuntimeError(f'Unstable symbol results for {query}')
                            checksums[query] = value
                    phase_latencies['query'].append(time.monotonic_ns() - phase_started)
                    client.checkpoint(f'queried-{cycle}')
                    phase_started = time.monotonic_ns()
                    for index, (name, _) in enumerate(sources):
                        client.notify('textDocument/didClose', dict(
                            textDocument=dict(uri=(root / f'{index}-{name}').as_uri())))
                    remaining = client.request('workspace/symbol', dict(query='type'))
                    if remaining:
                        raise RuntimeError('Closed documents still returned workspace symbols')
                    phase_latencies['close'].append(time.monotonic_ns() - phase_started)
                    client.checkpoint(f'closed-{cycle}')
                if args.rounds != 0 and not any(value['count'] for value in checksums.values()):
                    raise RuntimeError('No workspace symbols were exercised')
                client.request('shutdown', None)
                client.notify('exit', None)
                process.wait(timeout=10)
                if process.returncode != 0:
                    raise RuntimeError(f'ZLS exited with {process.returncode}')
            except BaseException:
                stderr.seek(0)
                print(stderr.read(), file=sys.stderr)
                raise
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdin.close()
                process.stdout.close()
            stderr.seek(0)
            stderr_output = stderr.read()
            closed_samples = [sample for sample in client.samples
                              if sample['phase'].startswith('closed-')]
            summary = dict(
                initialized_rss_kib=client.samples[0]['rss_kib'],
                observed_peak_kib=client.observed_peak_kib,
                max_virtual_kib=max(sample['virtual_kib'] for sample in client.samples),
                max_swap_kib=max(sample['swap_kib'] for sample in client.samples),
                max_threads=max(sample['threads'] for sample in client.samples),
                first_closed_rss_kib=closed_samples[0]['rss_kib'],
                last_closed_rss_kib=closed_samples[-1]['rss_kib'],
                closed_rss_delta_kib=(closed_samples[-1]['rss_kib'] -
                                      closed_samples[0]['rss_kib']),
            )
            print(json.dumps(dict(
                binary=str(args.binary.resolve()), cycles=args.cycles, rounds=args.rounds,
                sources=[dict(path=str(path.resolve()), bytes=path.stat().st_size,
                              sha256=hashlib.sha256(path.read_bytes()).hexdigest()) for path in args.sources],
                elapsed_s=time.monotonic() - started, summary=summary,
                samples=client.samples, results=checksums, stderr=stderr_output,
                median_phase_us={phase: sorted(values)[len(values) // 2] / 1000
                                 for phase, values in phase_latencies.items()},
                median_request_us={query: sorted(values)[len(values) // 2] / 1000
                                   for query, values in latencies.items()}), indent=2))


if __name__ == '__main__':
    main()
