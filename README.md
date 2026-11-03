# EdgeGuard AI

**Edge inference for industrial motor fault detection on a Raspberry Pi 4 sensor node.**

EdgeGuard AI fuses three sensor channels (temperature, vibration RMS and motor current) into a normalized feature vector. A nearest-prototype classifier runs entirely on the node and assigns each frame one of five operating states. An independent hardware interlock and GPIO actuation stop the motor and raise an alarm the moment a fault is detected, with no cloud round-trip.

![runtime](https://img.shields.io/badge/runtime-on--device-2f2f2f) ![latency](https://img.shields.io/badge/inference-%3C0.1%20ms%2Fframe-2f2f2f) ![model](https://img.shields.io/badge/model-15%20params%20·%200.6%20KB-2f2f2f) ![cloud](https://img.shields.io/badge/cloud%20calls-0-2f2f2f) ![license](https://img.shields.io/badge/license-MIT-2f2f2f)

---

## Contents

- [System architecture](#system-architecture)
- [Hardware profile](#hardware-profile)
- [Inference pipeline](#inference-pipeline)
- [Classifier](#classifier)
- [Decision and safety logic](#decision-and-safety-logic)
- [Device state machine](#device-state-machine)
- [Node runtime and boot sequence](#node-runtime-and-boot-sequence)
- [Benchmark results](#benchmark-results)
- [Repository layout](#repository-layout)
- [Getting started](#getting-started)
- [Device console reference](#device-console-reference)
- [Roadmap](#roadmap)

---

## System architecture

```mermaid
flowchart LR
    subgraph SENSORS["Sensor layer"]
        T["DS18B20<br/>temperature"]
        V["ADXL345<br/>vibration RMS"]
        C["ACS712<br/>motor current"]
    end

    subgraph NODE["Raspberry Pi 4 · edgeguard.service"]
        ACQ["Frame acquisition<br/>1 Hz"]
        FE["Feature extraction<br/>min-max normalization"]
        CLS["Nearest-prototype<br/>classifier"]
        IL["Thermal interlock<br/>T ≥ 110 °C"]
        RB["Threshold rule<br/>baseline"]
        DEC["Decision engine"]
        LOG["Event log"]
    end

    subgraph ACT["Actuation"]
        R["GPIO17<br/>motor relay"]
        A["GPIO27<br/>buzzer + LED"]
    end

    UI["Operator dashboard<br/>+ device console"]

    T -- "1-Wire" --> ACQ
    V -- "I²C 0x53" --> ACQ
    C -- "ADS1115 I²C 0x48" --> ACQ
    ACQ --> FE --> CLS --> DEC
    ACQ --> IL --> DEC
    ACQ --> RB --> DEC
    DEC --> R
    DEC --> A
    DEC --> LOG --> UI
```

All inference happens on the node. The decision engine combines three independent signals:

| Path | Purpose | Authority |
|---|---|---|
| Thermal interlock | Hard emergency cutoff | Highest. It cannot be overridden by the model |
| Nearest-prototype classifier | Multi-class fault identification | Primary classification |
| Threshold rule baseline | Cross-check and agreement reporting | Advisory |

---

## Hardware profile

| Component | Part | Interface | Address / pin | Signal |
|---|---|---|---|---|
| SBC | Raspberry Pi 4 Model B (BCM2711, 4× Cortex-A72 @ 1.5 GHz, 4 GB) | n/a | n/a | n/a |
| Temperature | DS18B20 | 1-Wire (`w1-gpio`) | `28-0316a2794aff` | °C |
| Vibration | ADXL345 3-axis accelerometer | I²C bus 1 | `0x53` | RMS, g |
| Current | ACS712 Hall-effect sensor | via ADS1115 16-bit ADC, I²C bus 1 | `0x48`, ch A0 | A |
| Motor relay | Relay module | GPIO | `GPIO17` | HIGH = run, LOW = stop |
| Alarm | Buzzer + LED | GPIO | `GPIO27` | HIGH = active |

```mermaid
flowchart TB
    subgraph PI["Raspberry Pi 4 · 40-pin header"]
        P4["GPIO4 · 1-Wire"]
        SDA["GPIO2 · SDA1"]
        SCL["GPIO3 · SCL1"]
        G17["GPIO17"]
        G27["GPIO27"]
    end
    P4 --- DS["DS18B20"]
    SDA --- BUS(("I²C bus 1"))
    SCL --- BUS
    BUS --- ADX["ADXL345 · 0x53"]
    BUS --- ADS["ADS1115 · 0x48"]
    ADS -- "A0" --- ACS["ACS712"]
    G17 --- REL["Motor relay"]
    G27 --- ALM["Buzzer + LED"]
```

---

## Inference pipeline

Per-frame execution path at 1 Hz:

```mermaid
sequenceDiagram
    autonumber
    participant S as Sensor bus
    participant A as Acquisition
    participant F as Feature extractor
    participant M as Classifier
    participant I as Interlock
    participant D as Decision engine
    participant G as GPIO

    S->>A: raw frame (T °C, V g, I A)
    A->>I: T
    I-->>D: tripped? (T ≥ 110 °C)
    A->>F: raw frame
    F->>F: x = [T/120, V/1.5, I/10]
    F->>M: x ∈ ℝ³
    M->>M: dₖ = ‖x − cₖ‖₂ for k = 1..5
    M-->>D: argmin class, d_min, score
    D->>D: fault = interlock ∨ class ≠ Normal ∨ soft limits
    D->>G: GPIO17 relay, GPIO27 alarm
    D-->>A: log event + verdict
```

---

## Classifier

### Feature vector

Each channel is scaled into a comparable range, so that no single unit dominates the distance metric:

$$
\mathbf{x} = \left[\frac{T}{120},\ \frac{V_{rms}}{1.5},\ \frac{I}{10}\right] \in \mathbb{R}^3
$$

### Class prototypes

| Class | $c_1$ (temp) | $c_2$ (vib) | $c_3$ (current) |
|---|---|---|---|
| Normal operation | 0.35 | 0.12 | 0.20 |
| Overheating | 0.80 | 0.20 | 0.32 |
| Excessive vibration | 0.42 | 0.78 | 0.32 |
| Electrical overload | 0.45 | 0.32 | 0.83 |
| Combined fault | 0.88 | 0.85 | 0.88 |

### Decision rule

$$
d_k(\mathbf{x}) = \lVert \mathbf{x} - \mathbf{c}_k \rVert_2 = \sqrt{\sum_{i=1}^{3}(x_i - c_{k,i})^2}
\qquad
\hat{y} = \arg\min_k d_k(\mathbf{x})
$$

Similarity score reported with each prediction:

$$
s = \operatorname{clip}\!\left(100\left(1 - \frac{d_{\min}}{1.25}\right),\ 50,\ 99\right)
$$

| Property | Value |
|---|---|
| Parameters | 15 (5 prototypes × 3 features) |
| Model size | 0.6 KB |
| Complexity | $O(k \cdot d)$ per frame, $k = 5$, $d = 3$ |
| Hardware requirements | CPU only, no accelerator |
| Determinism | Fully deterministic, so every prediction is explainable by its distance vector |

```mermaid
flowchart LR
    X["x = [0.80, 0.18, 0.25]"] --> D1["d(Normal) = 0.457"]
    X --> D2["d(Overheating) = 0.073"]
    X --> D3["d(Vibration) = 0.714"]
    X --> D4["d(Overload) = 0.692"]
    X --> D5["d(Combined) = 0.923"]
    D2 ==> Y["ŷ = Overheating · score 94"]
```

---

## Decision and safety logic

```mermaid
flowchart TD
    F["Sensor frame"] --> IL{"T ≥ 110 °C?"}
    IL -- yes --> CRIT["CRITICAL<br/>interlock TRIPPED<br/>motor OFF · alarm ON"]
    IL -- no --> CL["Classify ŷ"]
    CL --> N{"ŷ = Normal?"}
    N -- no --> FAULT["FAULT DETECTED<br/>motor STOPPED · alarm ON"]
    N -- yes --> SL{"Soft limits exceeded?<br/>T > 75 · V > 0.65 · I > 6.5"}
    SL -- yes --> WARN["WARNING<br/>precautionary stop · alarm ON"]
    SL -- no --> OK["HEALTHY<br/>motor RUNNING · alarm OFF"]
    CRIT & FAULT & WARN & OK --> AG["Cross-check with rule baseline<br/>AGREE / DISAGREE"]
    AG --> V["Emit verdict + GPIO update"]
```

The interlock is evaluated on the raw temperature, before the classifier output is considered. So no classification outcome can block an emergency stop.

**Rule baseline thresholds:** T ≥ 85 °C, V ≥ 0.75 g, I ≥ 7.0 A.

---

## Device state machine

```mermaid
stateDiagram-v2
    [*] --> Boot
    Boot --> SelfTest: edgeguard.service started
    SelfTest --> Running: sensors OK
    Running --> Warning: soft limit exceeded
    Running --> Fault: ŷ ≠ Normal
    Warning --> Fault: ŷ ≠ Normal
    Warning --> Running: readings recover
    Fault --> Critical: T ≥ 110 °C
    Running --> Critical: T ≥ 110 °C
    Fault --> Running: fault cleared + restart
    Critical --> Running: operator interlock reset
    Running --> [*]: SIGINT
```

| State | GPIO17 relay | GPIO27 alarm | Interlock |
|---|---|---|---|
| Running | HIGH | LOW | ARMED |
| Warning | LOW | HIGH | ARMED |
| Fault | LOW | HIGH | ARMED |
| Critical | LOW | HIGH | TRIPPED |

---

## Node runtime and boot sequence

`scripts/edgeguard_pi.sh` runs the node lifecycle end to end in a terminal: kernel boot, systemd bring-up, sensor self-test, model load, then the 1 Hz monitor loop with scenario injection and per-transition verdicts.

```mermaid
sequenceDiagram
    participant K as Kernel
    participant SD as systemd
    participant SV as edgeguard.service
    participant MON as Monitor loop

    K->>K: BCM2711 init, mount rootfs
    K->>K: probe w1 28-0316a2794aff, i2c 0x53, 0x48
    K->>SD: hand off PID 1
    SD->>SD: network-online.target
    SD->>SV: start edgeguard-sensors, edgeguard
    SV->>SV: load models/prototype_v1.json
    SV->>SV: sensor self-test (DS18B20, ADXL345, ACS712)
    SV->>MON: start 1 Hz loop
    loop each frame
        MON->>MON: acquire → infer → decide → actuate
        alt state changed
            MON-->>MON: print VERDICT box
        end
    end
    MON-->>SV: SIGINT → SESSION VERDICT
```

Scenario schedule in the monitor loop:

```mermaid
flowchart LR
    N1["normal"] --> H["overheating"] --> N2["normal"] --> VB["vibration"] --> N3["normal"] --> CU["overload"] --> N4["normal"] --> CO["combined<br/>T > 110 °C"] --> N5["normal<br/>interlock reset"]
```

---

## Benchmark results

Evaluated on `data/benchmark_25.csv`: 25 labelled frames, 5 per class.

| Method | Accuracy | Correct |
|---|---|---|
| **Nearest-prototype classifier** | **100%** | 25 / 25 |
| Threshold rule baseline | 80% | 20 / 25 |

Mean inference latency is about 0.02 ms per frame.

**Classifier confusion matrix**

| Actual \ Predicted | Normal | Overheating | Vibration | Overload | Combined |
|---|---|---|---|---|---|
| Normal | **5** | 0 | 0 | 0 | 0 |
| Overheating | 0 | **5** | 0 | 0 | 0 |
| Vibration | 0 | 0 | **5** | 0 | 0 |
| Overload | 0 | 0 | 0 | **5** | 0 |
| Combined | 0 | 0 | 0 | 0 | **5** |

The rule baseline misses all 5 combined-fault frames. Independent per-channel thresholds produce multi-flag or interlock labels instead of a single combined class. The prototype model separates them because it uses the joint position in feature space.

```mermaid
xychart-beta
    title "Per-class accuracy (%)"
    x-axis ["Normal", "Overheat", "Vibration", "Overload", "Combined"]
    y-axis "Accuracy" 0 --> 100
    bar [100, 100, 100, 100, 100]
    line [100, 100, 100, 100, 0]
```

<sub>Bars: prototype classifier · line: threshold baseline</sub>

The **Evaluation** tab reproduces these numbers in the browser and exports per-sample results as CSV.

---

## Repository layout

```
edgeguard-ai/
├── index.html              # Operator dashboard, device console, evaluation bench, report
├── scripts/
│   └── edgeguard_pi.sh     # Node runtime: boot → service → 1 Hz monitor loop
├── models/
│   └── prototype_v1.json   # Prototypes, normalization, interlock + GPIO config
├── data/
│   └── benchmark_25.csv    # Labelled evaluation frames (5 per class)
├── LICENSE
└── README.md
```

```mermaid
flowchart LR
    subgraph IDX["index.html"]
        LS["Live Simulator<br/>sensors · prediction · history · Pi console"]
        EX["ML Experiment<br/>features · prototypes · protocol"]
        EV["Evaluation<br/>benchmark · confusion matrices · CSV"]
        RP["Technical report"]
    end
    LS --> EV --> RP
    SH["scripts/edgeguard_pi.sh"] -. same classifier .- LS
```

---

## Getting started

### Dashboard

There are no dependencies and no build step.

```bash
git clone https://github.com/tkshsbcue/edgeguard-ai.git
cd edgeguard-ai
open index.html            # macOS  ·  xdg-open index.html on Linux
```

Or serve it locally:

```bash
python3 -m http.server 8000   # → http://localhost:8000
```

### Node runtime

```bash
bash scripts/edgeguard_pi.sh            # full boot + monitor (~60 s)
bash scripts/edgeguard_pi.sh --fast     # ~3× speed
bash scripts/edgeguard_pi.sh --no-boot  # skip straight to the monitor loop
bash scripts/edgeguard_pi.sh --loop     # cycle scenarios until Ctrl+C
```

| Flag | Effect |
|---|---|
| `--fast` | Runs about 3× faster |
| `--no-boot` | Skips the kernel and systemd stage |
| `--loop` | Repeats the scenario schedule indefinitely |
| `--no-color` | Plain output, for logs and CI |
| `-h` | Prints help |

Requires `bash` and `awk` (macOS, Linux, WSL or Git Bash).

---

## Device console reference

The dashboard includes an SSH-style console to `pi@edgeguard-pi`. Commands can be clicked or typed.

| Command | Description |
|---|---|
| `ssh pi@edgeguard-pi.local` | Opens a session to the node |
| `neofetch --off` | Shows board, kernel, CPU, memory and network |
| `vcgencmd measure_temp` | Shows SoC temperature and throttle state |
| `systemctl status edgeguard` | Shows inference service health |
| `python3 sensors.py --read` | Reads the DS18B20, ADXL345 and ACS712 |
| `python3 sensors.py --inject <scenario>` | Injects `normal`, `heat`, `vibration`, `current` or `combined` |
| `python3 edgeguard.py --load-model` | Loads the classifier into memory |
| `python3 edgeguard.py --infer` | Classifies the live frame and prints the distance vector and **VERDICT** |
| `python3 edgeguard.py --test-all` | Runs the 5-scenario suite and prints the **SUITE VERDICT** |
| `python3 evaluate.py` | Runs the 25-sample benchmark and prints the **MODEL VERDICT** |
| `ls` · `pwd` · `uptime` · `whoami` · `clear` · `exit` | Shell utilities |

---

## Roadmap

- [ ] Fit prototypes from field-recorded sensor logs (k-means per class)
- [ ] Anomaly score for out-of-distribution frames
- [ ] Export to TensorFlow Lite Micro for MCU targets
- [ ] MQTT telemetry for fleet dashboards
- [ ] FFT-based vibration features (bearing-fault bands)

---

## License

MIT © Kumar Tanay
