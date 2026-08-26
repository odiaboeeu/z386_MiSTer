# z486 MiSTer Verilator harness

## Build

The default simulator includes the x87 unit, matching the MiSTer build:

```sh
make
```

Use the explicit reduced target only when testing behavior without an FPU:

```sh
make no_x87
```

The binaries are `obj_dir/Vz486_mister_sim` and
`obj_dir_no_x87/Vz486_mister_sim`, respectively.

## Disk images

Use `--disk` for the IDE0 hard-disk image and `--cdrom` for an IDE1 ISO image:

```sh
./obj_dir/Vz486_mister_sim \
  --disk /tmp/dos.vhd \
  --cdrom /tmp/game.iso
```

The CD-ROM model implements the ATAPI packet commands used by DOS CD drivers.
Audio-track playback is accepted for software compatibility but is not rendered
by the simulator.

## Live control socket

Start the simulator with a localhost TCP control socket:

```sh
./obj_dir/Vz486_mister_sim --disk ../../sdcard/win311_auto.vhd --control-port 9386
```

Send a single command with `simctl.py`:

```sh
./simctl.py status
./simctl.py mouse -20 -40 0
./simctl.py key enter
./simctl.py screenshot /tmp/z486.png
./simctl.py checkpoint
```

With no command arguments, `simctl.py` keeps one connection open and streams
commands from stdin. This preserves the ordering of mouse motion, button, and
keyboard packets:

```sh
printf '%s\n' \
  'mouse 0 0 1' \
  'mouse 10 -4 1' \
  'mouse 10 -4 1' \
  'mouse 0 0 0' | ./simctl.py
```

Commands are:

```text
mouse <dx> <dy> [buttons]
key <name> [press|down|up]
checkpoint
screenshot [path]
status
quit
```

PS/2 mouse Y is positive upward and negative downward. Mouse button bits are
left=1, right=2, and middle=4. The server binds to `127.0.0.1` by default; use
`--control-bind 0.0.0.0` only when control from another machine is intended.

## Periodic checkpoints

For long boot or application runs, save a bounded set of rotating checkpoints:

```sh
./obj_dir/Vz486_mister_sim \
  --disk /tmp/test.vhd \
  --checkpoint-dir /tmp/test-checkpoints \
  --checkpoint-interval-sec 30 \
  --checkpoint-keep 4
```

Restore the nearest checkpoint before a failure and trace only the remaining
window:

```sh
./obj_dir/Vz486_mister_sim \
  --restore /tmp/test-checkpoints/ckpt_0000000123611872 \
  --trace --trace-start 247300000 --end 263000000
```

The interval is wall-clock seconds. The checkpoint name and trace boundaries
use simulator time (`2 * cycle`). Each full-system checkpoint can consume
hundreds of megabytes, so keep retention bounded.
