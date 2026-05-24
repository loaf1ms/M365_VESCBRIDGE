# M365 VESC Dashboard Script

A VESC Lisp script for Xiaomi M365/Pro dashboard compatibility.

---

## Wiring

<img width="265" height="298" alt="image" src="https://github.com/user-attachments/assets/d86fba31-5be0-4c3d-97ca-a7e1fee57dcd" />


---

## Speed Modes

Cycle through modes with a **double press** of the power button.

|  Mode | Default Speed |
|-------|--------------|
| Sport | 25 km/h |
| Drive | 20 km/h |
| Eco   | 15 km/h  |

> Speed limits are set in the top of the script under user params. Only max speed is controlled — watt limits and current scaling are left to VESC.

---

## Controls

| Action | Result |
|--------|--------|
| Single press | Toggle light |
| Double press | Cycle speed mode (sport → eco → drive → sport) |
| Hold brake + double press | Toggle lock mode |
| Hold brake + throttle + single press | Toggle secret unlimited speed |
| Hold 6 seconds | Turn screen off |
| Single press when off | Wake screen |

---

## Features

### Speed Modes
Three modes selectable via double press. Each sets a different max speed in VESC. No watt or current limits, just speed cap.

### Secret Mode
Hold both brake and throttle fully, then single press. Toggles unlimited speed (100 km/h cap, effectively no limit). Indicated by battery % disappearing from idle display. Resets automatically when screen is turned off.

### Lock Mode
Hold brake and double press. Prevents throttle input and applies full brake if the scooter is rolled. Beeps continuously if moving while locked. Cannot be enabled while in secret mode.

### Light
Single press toggles the front light on/off. Light turns off automatically when screen is off.

### Battery in Idle
When standing still the speed field shows battery percentage instead of 0. Switches back to speed when moving.

### Temp Warning
If FET or motor temperature exceeds 60°C the temp warning icon appears on the display. Script still works normally, just a visual heads up.

---

## User Parameters

Found at the top of the script, safe to change:

```lisp
(def min-adc-brake 0.5)      ; how far brake must be pressed to register
(def min-adc-throttle 0.5)   ; how far throttle must be pressed for secret mode
(def show-batt-in-idle 1)    ; 1=show battery when still, 0=always show speed

(def eco-speed (/ 7 3.6))    ; eco mode speed limit in km/h
(def drive-speed (/ 17 3.6)) ; drive mode speed limit in km/h
(def sport-speed (/ 25 3.6)) ; sport mode speed limit in km/h
(def secret-speed (/ 100 3.6)) ; secret mode speed limit in km/h
```

---

## Notes

- If speed limiting feels bumpy/stuttery at low speeds, lower the speed control P gain in VESC Tool under Motor Settings → PID. Default is usually too aggressive for low speed caps.
- Script does not interfere with ADC1 or ADC2 at all. Throttle and brake are handled entirely by VESC.
- No CAN support — single motor only.
