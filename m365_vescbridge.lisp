; M365 dashboard - by @loaf1ms

; UART setup
(uart-start 115200 'half-duplex)
(gpio-configure 'pin-rx 'pin-mode-in-pu)
(def tx-frame (array-create 14))
(bufset-u16 tx-frame 0 0x55AA)
(bufset-u16 tx-frame 2 0x0821)
(bufset-u16 tx-frame 4 0x6400)
(def uart-buf (array-create 64))

; User params
(def min-adc-brake 0.1)
(def min-adc-throttle 0.1)
(def min-speed 1)
(def button-safety-speed (/ 5 3.6))
(def show-batt-in-idle 1)

; Speed modes (km/h, watts)
(def eco-speed   (/ 15  3.6))
(def eco-watts   300)
(def drive-speed (/ 20 3.6))
(def drive-watts 600)
(def sport-speed (/ 25 3.6))
(def sport-watts 900)

; Secret mode
(def secret-speed (/ 100 3.6))
(def secret-watts 1500000)
(def secret-fw    20.0) ; field weakening amps

; States
(def light 0)
(def off 0)
(def speedmode 4)  ; 1=drive 2=eco 4=sport
(def unlock 0)
(def presstime (systime))
(def releasetime (systime))
(def presses 0)
(def feedback 0)

; Soft speed limit state
(def current-limit 1.0)

(defun apply-mode()
    (if (= unlock 1)
        {
            (conf-set 'max-speed secret-speed)
            (conf-set 'l-watt-max secret-watts)
            (conf-set 'foc-fw-current-max secret-fw)
        }
        {
            (conf-set 'foc-fw-current-max 0)
            (cond
                ((= speedmode 1)
                    {
                        (conf-set 'max-speed drive-speed)
                        (conf-set 'l-watt-max drive-watts)
                    }
                )
                ((= speedmode 2)
                    {
                        (conf-set 'max-speed eco-speed)
                        (conf-set 'l-watt-max eco-watts)
                    }
                )
                ((= speedmode 4)
                    {
                        (conf-set 'max-speed sport-speed)
                        (conf-set 'l-watt-max sport-watts)
                    }
                )
            )
        }
    )
)

; Soft speed limiter - runs in its own thread
; Instead of hard PID cutoff, it gently reduces current scale
; as speed approaches the limit, eliminating the oscillation
(defun soft-speed-limit()
    (loopwhile t
        {
            (var spd (* (get-speed) 3.6))
            (var limit (*
                (if (= unlock 1) (* secret-speed 3.6)
                    (if (= speedmode 1) (* drive-speed 3.6)
                        (if (= speedmode 2) (* eco-speed 3.6)
                            (* sport-speed 3.6)
                        )
                    )
                )
            1.0))

            ; start backing off at 85% of speed limit
            (var soft-start (* limit 0.85))

            (if (>= spd soft-start)
                ; linearly scale current from 1.0 down to 0.0
                ; as speed goes from soft-start to limit
                (set 'current-limit
                    (- 1.0 (/ (- spd soft-start) (- limit soft-start)))
                )
                (set 'current-limit 1.0)
            )

            ; clamp between 0 and 1
            (if (< current-limit 0.0) (set 'current-limit 0.0))
            (if (> current-limit 1.0) (set 'current-limit 1.0))

            (conf-set 'l-current-max-scale current-limit)
            (sleep 0.05)
        }
    )
)

(defun update-dash()
    {
        (var current-speed (* (get-speed) 3.6))
        (var battery (* (get-batt) 100))

        ; mode field (1=drive 2=eco 4=sport 16=off 128=temp)
        (if (= off 1)
            (bufset-u8 tx-frame 6 16)
            (if (or (> (get-temp-fet) 60) (> (get-temp-mot) 60))
                (bufset-u8 tx-frame 6 (+ 128 speedmode))
                (bufset-u8 tx-frame 6 speedmode)
            )
        )

        (bufset-u8 tx-frame 7 battery)

        (if (= off 0)
            (bufset-u8 tx-frame 8 light)
            (bufset-u8 tx-frame 8 0)
        )

        (if (> feedback 0)
            {
                (bufset-u8 tx-frame 9 1)
                (set 'feedback (- feedback 1))
            }
            (bufset-u8 tx-frame 9 0)
        )

        (if (= show-batt-in-idle 1)
            (if (> current-speed 1)
                (bufset-u8 tx-frame 10 (to-i (+ current-speed 0.5)))
                (bufset-u8 tx-frame 10 battery)
            )
            (bufset-u8 tx-frame 10 current-speed)
        )

        (bufset-u8 tx-frame 11 (get-fault))

        (var crc 0)
        (looprange i 2 12
            (set 'crc (+ crc (bufget-u8 tx-frame i)))
        )
        (var c-out (bitwise-xor crc 0xFFFF))
        (bufset-u8 tx-frame 12 c-out)
        (bufset-u8 tx-frame 13 (shr c-out 8))
        (uart-write tx-frame)
    }
)

(defun read-frames()
    (loopwhile t
        {
            (uart-read-bytes uart-buf 3 0)
            (if (= (bufget-u16 uart-buf 0) 0x55aa)
                {
                    (var len (bufget-u8 uart-buf 2))
                    (var crc len)
                    (if (and (> len 0) (< len 60))
                        {
                            (uart-read-bytes uart-buf (+ len 4) 0)
                            (looprange i 0 len
                                (set 'crc (+ crc (bufget-u8 uart-buf i)))
                            )
                            (if (= (+ (shl (bufget-u8 uart-buf (+ len 2)) 8) (bufget-u8 uart-buf (+ len 1))) (bitwise-xor crc 0xFFFF))
                                (update-dash)
                            )
                        }
                    )
                }
            )
        }
    )
)

(defun handle-button()
    (if (= presses 1)
        (if (= off 1)
            {
                (set 'off 0)
                (set 'feedback 1)
                (apply-mode)
            }
            (if (and (> (get-adc-decoded 1) min-adc-brake)
                     (> (get-adc-decoded 0) min-adc-throttle))
                ; brake + throttle + single press = toggle secret
                {
                    (set 'unlock (bitwise-xor unlock 1))
                    (set 'feedback 2)
                    (apply-mode)
                }
                (set 'light (bitwise-xor light 1))
            )
        )
        (if (>= presses 2)
            ; double press = cycle speed modes
            (if (= unlock 0)
                {
                    (cond
                        ((= speedmode 4) (set 'speedmode 2))
                        ((= speedmode 2) (set 'speedmode 1))
                        ((= speedmode 1) (set 'speedmode 4))
                    )
                    (set 'feedback 1)
                    (apply-mode)
                }
            )
        )
    )
)

(defun reset-button()
    {
        (set 'presstime (systime))
        (set 'releasetime (systime))
        (set 'presses 0)
    }
)

(defun button-logic()
    {
        (var buttonold 0)
        (loopwhile t
            {
                (var button (gpio-read 'pin-rx))
                (sleep 0.05)
                (var buttonconfirm (gpio-read 'pin-rx))
                (if (not (= button buttonconfirm))
                    (set 'button 0)
                )

                (if (> buttonold button)
                    {
                        (if (= presses 0)
                            (set 'presstime (systime))
                        )
                        (set 'presses (+ presses 1))
                    }
                )

                (if (< buttonold button)
                    (set 'releasetime (systime))
                )

                (var held (- (systime) presstime))
                (var since-release (- (systime) releasetime))
                (var is-active (or (= off 1) (<= (get-speed) button-safety-speed)))

                (if (and (= button 0) (> presses 0) (> held 6000))
                    {
                        (set 'off 1)
                        (set 'light 0)
                        (set 'unlock 0)
                        (set 'feedback 1)
                        (apply-mode)
                        (reset-button)
                    }
                    (if (and (> presses 0) (= button 1) (> since-release 300))
                        {
                            (if is-active (handle-button))
                            (reset-button)
                        }
                    )
                )

                (set 'buttonold button)
            }
        )
    }
)

(apply-mode)
(spawn 150 read-frames)
(spawn 64 soft-speed-limit)
(button-logic)
