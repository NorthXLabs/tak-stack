# hello-cot

Two small scripts for learning Cursor on Target (CoT).

## Setup

```sh
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Listen to the mesh

```sh
python listen.py --interface <your-computer-ip>
```

## Put a truck on the map

```sh
python hello_cot.py --lat <latitude> --lon <longitude> --interface <your-computer-ip>
```

If multicast doesn't reach your device, send directly to its IP address instead:

```sh
python hello_cot.py --lat <latitude> --lon <longitude> --target <device-ip>:4242
```

Your computer and device must be on the same network. Press Ctrl+C to stop.

Only use these on a network you control. Don't send test data onto a network that real teams are using.
