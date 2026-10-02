#!/usr/bin/env python3
"""
daq_trigger_out.py
==================
Continuously send TTL-like trigger pulses to Brainsight on the NI USB-6361's
analog output, so you can confirm on the Brainsight side that triggers are
being received and tracked (each one is logged as a ``TTL Trigger`` row in the
streamed export).

This is the *send-only* companion to ``daq_trigger_monitor.py``: it generates
the exact same pulse (rising 0->5 V, 10 ms, on ao1) but repeats it on a fixed
interval and does NOT measure it back. Watch Brainsight's UI / streamed file to
verify reception.

HARDWARE
--------
NI USB-6361 (X Series). Uses analog output ao1 (this board has only ao0/ao1).
The pulse matches Brainsight's trigger spec: rising 0-5 V, > 5 ms wide.

WIRING
------
  AO1 (BNC) --> Brainsight trigger input.
  The waveform starts and ends at 0 V, so the AO line rests at baseline
  between pulses and each pulse is a clean rising edge.

REQUIREMENTS
------------
  - NI-DAQmx driver installed, device visible in NI MAX (confirm DEV below).
  - pip install nidaqmx numpy
  - Run with --dry-run to test the loop with no hardware / no nidaqmx.

OWNERSHIP
---------
  Reserves AO1 while it runs. Close any other program (e.g. QtracP, or
  daq_trigger_monitor.py) that is using the DAQ before running it.

EXAMPLES
--------
    # 1 pulse/second on Dev1/ao1, forever:
    python3 python/daq_trigger_out.py

    # 2 pulses/second, stop after 50 pulses:
    python3 python/daq_trigger_out.py --interval 0.5 --count 50

    # Test the loop with no hardware:
    python3 python/daq_trigger_out.py --dry-run
"""

import argparse
import sys
import time

# ----------------------------------------------------------------------
# CONFIGURATION  -- defaults match daq_trigger_monitor.py
# ----------------------------------------------------------------------
DEV         = "Dev1"      # device name from NI MAX
AO_CHAN     = "ao1"       # USB-6361 has only ao0 / ao1 (no ao2)

FS_AO       = 1_000_000   # AO sample rate, S/s

PULSE_V     = 5.0         # pulse amplitude (V)  -- Brainsight wants ~0-5 V rising
BASELINE_V  = 0.0         # baseline level (V)
PRE_MS      = 3.0         # baseline before the pulse (ms) -- clean rising edge
PULSE_MS    = 10.0        # pulse width (ms)  -- Brainsight wants > 5 ms
POST_MS     = 5.0         # baseline after the pulse (ms) -- AO returns to 0 V
# ----------------------------------------------------------------------


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Continuously send 0-5 V trigger pulses to Brainsight via NI-DAQ analog output.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--device", default=DEV,
                   help="NI-DAQ device name (from NI MAX).")
    p.add_argument("--ao-chan", default=AO_CHAN,
                   help="Analog-output channel driving Brainsight's trigger input.")
    p.add_argument("--interval", type=float, default=1.0,
                   help="Seconds between pulses (e.g. 0.5 = 2 Hz).")
    p.add_argument("--amplitude", type=float, default=PULSE_V,
                   help="Pulse amplitude in volts.")
    p.add_argument("--width-ms", type=float, default=PULSE_MS,
                   help="Pulse width in milliseconds.")
    p.add_argument("--count", type=int, default=0,
                   help="Number of pulses to send, then stop (0 = run forever).")
    p.add_argument("--dry-run", action="store_true",
                   help="Don't touch hardware; just log what would be sent (no nidaqmx needed).")
    return p.parse_args(argv)


def build_pulse_waveform(amplitude, width_ms):
    """Return (waveform, total_ms) for one finite AO generation.

    Baseline -> pulse -> baseline, so the line rests at 0 V between pulses and
    each pulse is a clean rising edge (same shape as daq_trigger_monitor.py).
    """
    import numpy as np
    n_pre   = int(round(PRE_MS  * FS_AO / 1000.0))
    n_pulse = int(round(width_ms * FS_AO / 1000.0))
    n_post  = int(round(POST_MS * FS_AO / 1000.0))
    wave = np.concatenate([
        np.full(n_pre,   BASELINE_V),
        np.full(n_pulse, amplitude),
        np.full(n_post,  BASELINE_V),
    ]).astype(np.float64)
    total_ms = PRE_MS + width_ms + POST_MS
    return wave, total_ms


def make_sender(device, ao_chan, amplitude, width_ms, dry_run):
    """Return (pulse_fn, close_fn). pulse_fn() emits one pulse; close_fn() releases HW."""
    if dry_run:
        gen_ms = PRE_MS + width_ms + POST_MS

        def pulse():
            time.sleep(gen_ms / 1000.0)

        def close():
            pass

        return pulse, close

    try:
        import nidaqmx
        from nidaqmx.constants import AcquisitionType
    except ImportError:
        sys.exit(
            "ERROR: the 'nidaqmx' (and numpy) package is not installed.\n"
            "       Install with:  pip install nidaqmx numpy\n"
            "       (or run with --dry-run to test the loop without hardware)."
        )

    wave, _ = build_pulse_waveform(amplitude, width_ms)
    n_ao = wave.size

    task = nidaqmx.Task()
    try:
        task.ao_channels.add_ao_voltage_chan(
            f"{device}/{ao_chan}", min_val=0.0, max_val=amplitude)
        task.timing.cfg_samp_clk_timing(
            FS_AO, sample_mode=AcquisitionType.FINITE, samps_per_chan=n_ao)
    except Exception as exc:  # noqa: BLE001 - surface DAQmx errors plainly
        task.close()
        sys.exit(f"ERROR: could not open analog output '{device}/{ao_chan}': {exc}")

    timeout = max(1.0, (PRE_MS + width_ms + POST_MS) / 1000.0 * 5)

    def pulse():
        # Re-arm and fire the finite generation for each pulse.
        task.write(wave, auto_start=False)
        task.start()
        task.wait_until_done(timeout=timeout)
        task.stop()

    def close():
        task.close()

    return pulse, close


def main(argv=None):
    args = parse_args(argv)

    gen_ms = PRE_MS + args.width_ms + POST_MS
    if gen_ms / 1000.0 >= args.interval:
        sys.exit(
            f"ERROR: one pulse generation takes {gen_ms:.0f} ms "
            f"(pre {PRE_MS:g} + pulse {args.width_ms:g} + post {POST_MS:g}); "
            f"it must be shorter than the interval ({args.interval * 1000:.0f} ms)."
        )

    target = "DRY-RUN (no hardware)" if args.dry_run else f"{args.device}/{args.ao_chan}"
    limit = "forever" if args.count <= 0 else f"{args.count} pulses"
    rate_hz = 1.0 / args.interval if args.interval > 0 else float("inf")

    print("Brainsight DAQ trigger-out  (analog, send-only)")
    print(f"  target   : {target}")
    print(f"  pulse    : 0 -> {args.amplitude:g} V, {args.width_ms:g} ms wide "
          f"(pre {PRE_MS:g} ms / post {POST_MS:g} ms baseline)")
    print(f"  interval : {args.interval:g} s  (~{rate_hz:g} Hz)")
    print(f"  sending  : {limit}")
    print("  Watch Brainsight to confirm triggers are received. Ctrl+C to stop.\n")

    pulse, close = make_sender(
        args.device, args.ao_chan, args.amplitude, args.width_ms, args.dry_run)

    sent = 0
    next_due = time.monotonic()
    try:
        while args.count <= 0 or sent < args.count:
            pulse()
            sent += 1
            print(f"[{time.strftime('%H:%M:%S')}] trigger #{sent} sent", flush=True)
            # Keep a fixed cadence regardless of generation/print latency.
            next_due += args.interval
            sleep_s = next_due - time.monotonic()
            if sleep_s > 0:
                time.sleep(sleep_s)
            else:
                next_due = time.monotonic()   # fell behind; resync, don't burst
    except KeyboardInterrupt:
        print("\nStopped by user.")
    finally:
        close()
        print(f"Total triggers sent: {sent}")


if __name__ == "__main__":
    main()
