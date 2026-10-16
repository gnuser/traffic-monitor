"""macOS regression probe: nettop must not spin when used in the background."""
import resource
import subprocess
import tempfile
import time

before = resource.getrusage(resource.RUSAGE_CHILDREN)
started = time.monotonic()
with tempfile.TemporaryFile() as output:
    process = subprocess.Popen(
        ['/usr/bin/nettop', '-P', '-n', '-x', '-c', '-L', '0', '-s', '2',
         '-J', 'bytes_in,bytes_out'],
        stdin=subprocess.PIPE, stdout=output, stderr=subprocess.PIPE,
    )
    try:
        # Do not use communicate(): it closes stdin and triggers nettop's EOF loop.
        try:
            process.wait(timeout=8)
            raise AssertionError('collector exited before the measurement finished')
        except subprocess.TimeoutExpired:
            pass
    finally:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=3)
        process.stdin.close()
    output.seek(0)
    samples = output.read().count(b'bytes_in')
    error = process.stderr.read().decode()
    process.stderr.close()
after = resource.getrusage(resource.RUSAGE_CHILDREN)
seconds = time.monotonic() - started
cpu = (after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime) / seconds * 100
print(f'collector CPU: {cpu:.2f}%; snapshots: {samples}; duration: {seconds:.1f}s')
assert samples >= 2, f'No usable samples: {error}'
assert cpu < 20, f'Collector CPU regression: {cpu:.2f}%'
