#!/usr/bin/env python3
"""Exercise real progressive frames and cancellation at native render phases."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import time

from verify_cycles_native import author


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--device', choices=['cpu', 'metal'], default='cpu')
    args = parser.parse_args()
    root = args.output.resolve(); root.mkdir(parents=True, exist_ok=False)
    base = author(root, args.device)
    report = dict(device=args.device)

    def exercise(name, manifest, condition, delay=0):
        manifest = copy.deepcopy(manifest); manifest['outputDirectory'] = name
        path = root / (name + '.json'); path.write_text(json.dumps(manifest, indent=2) + '\n')
        messages = queue.Queue(); started = time.monotonic(); events = []; frames = []
        cancelled_at = None
        with (root / (name + '.stderr.log')).open('w') as errors:
            child = subprocess.Popen([str(args.helper.resolve()), '--render', str(path)],
                                     env=dict(os.environ, LAB_CYCLES_CACHE_DIR=str(root / 'cache')),
                                     stdout=subprocess.PIPE, stderr=errors, text=True)

            def receive():
                for line in child.stdout:
                    messages.put(json.loads(line))
                messages.put(None)

            reader = threading.Thread(target=receive, daemon=True); reader.start()
            try:
                while time.monotonic() - started < 180:
                    try:
                        event = messages.get(timeout=.5)
                    except queue.Empty:
                        continue
                    if event is None:
                        break
                    event['observedSeconds'] = time.monotonic() - started; events.append(event)
                    if event['type'] == 'frame':
                        saved = root / (name + '-frame-' + str(len(frames)) + '.png')
                        shutil.copyfile(event['framePath'], saved)
                        frames.append(dict(sample=event.get('sample', 0), path=str(saved),
                                           seconds=event['observedSeconds'], sha256=hashlib.sha256(saved.read_bytes()).hexdigest()))
                    if cancelled_at is None and condition(event, frames):
                        if delay:
                            time.sleep(delay)
                        cancelled_at = time.monotonic() - started; child.terminate()
                child.wait(timeout=30)
            finally:
                if child.poll() is None:
                    child.kill(); child.wait(timeout=10)
        (root / (name + '.events.json')).write_text(json.dumps(events, indent=2) + '\n')
        assert cancelled_at is not None, (name, 'Requested real phase not observed', events[-4:])
        assert any(event['type'] == 'cancelled' for event in events), (name, events[-4:])
        assert not any(event['type'] == 'completed' for event in events), (name, 'Cancelled render completed')
        report[name] = dict(cancelledAtSeconds=cancelled_at, terminalExit=child.returncode,
                            observedPhase=next((event.get('phase') for event in events if condition(event, frames)), None),
                            frames=frames)
        return events, frames

    progressive = copy.deepcopy(base)
    progressive.update(width=640, height=480, samples=4096, denoise=True)
    progressive['materials'][0].pop('displacementScaleMM')
    progressive['materials'][0]['textures'].pop('displacement')
    _, frames = exercise('progressive', progressive,
                         lambda event, frames: len(frames) >= 2 and 0 < event.get('sample', 0) < 4096)
    assert frames[0]['seconds'] < 15, frames[0]
    assert frames[0]['sample'] < 4096 and frames[1]['sample'] > frames[0]['sample'], frames
    assert frames[0]['sha256'] != frames[1]['sha256'], 'Progressive images did not evolve'

    preparation = copy.deepcopy(base)
    preparation.update(width=1024, height=1024, samples=8, displacementDicingRate=2,
                       displacementMaxTriangles=2_000_000)
    exercise('preparation', preparation, lambda event, _: event.get('phase') == 'preparing')

    denoising = copy.deepcopy(progressive)
    denoising.update(width=2048, height=2048, samples=8)
    exercise('denoising', denoising, lambda event, _: event.get('phase') == 'denoising', delay=.05)
    (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
