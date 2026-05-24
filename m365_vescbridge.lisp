; M365 dashboard - build by @loaf1ms

; UART setup
(uart-start 115200 'half-duplex)
(gpio-configure 'pin-rx 'pin-mode-in-pu)
(def tx-frame (array-create 14))
(bufset-u16 tx-frame 0 0x55AA)
(bufset-u16 tx-frame 2 0x0821)
(bufset-u16 tx-frame 4 0x6400)
(def uart-buf (array-create 64))

; User params
(def min-adc-brake 0.2)
(def min-adc-throttle 0.2)
(def min-speed 1)
(def button-safety-speed (/ 5 3.6))
(def show-batt-in-idle 1)

; Speed limits per mode (km/h)
(def eco-speed (/ 15 3.6))
(def drive-speed (/ 20 3.6))
(def sport-speed (/ 25 3.6))
(def secret-speed (/ 100 3.6))

; States
(def light 0)
(def off 0)
(def lock 0)
(def speedmode 4)
(def unlock 0)
(def presstime (systime))
(def releasetime (systime))
(def presses 0)
(def feedback 0)

(defun apply-mode()
    (if (= unlock 1)
        (conf-set 'max-speed secret-speed)
        (cond
            ((= speedmode 1) (conf-set 'max-speed drive-speed))
            ((= speedmode 2) (conf-set 'max-speed eco-speed))
            ((= speedmode 4) (conf-set 'max-speed sport-speed))
        )
    )
)

(defun update-dash()
    {
        (var current-speed (* (get-speed) 3.6))
        (var battery (* (get-batt) 100))

        (if (= off 1)
            (bufset-u8 tx-frame 6 16)
            (if (= lock 1)
                (bufset-u8 tx-frame 6 32)
                (if (or (> (get-temp-fet) 60) (> (get-temp-mot) 60))
                    (bufset-u8 tx-frame 6 (+ 128 speedmode))
                    (bufset-u8 tx-frame 6 speedmode)
                )
            )
        )

        (bufset-u8 tx-frame 7 battery)

        (if (= off 0)
            (bufset-u8 tx-frame 8 light)
            (bufset-u8 tx-frame 8 0)
        )

        (if (= lock 1)
            (if (> current-speed min-speed)
                (bufset-u8 tx-frame 9 1)
                (bufset-u8 tx-frame 9 0)
            )
            (if (> feedback 0)
                {
                    (bufset-u8 tx-frame 9 1)
                    (set 'feedback (- feedback 1))
                }
                (bufset-u8 tx-frame 9 0)
            )
        )

        (if (= show-batt-in-idle 1)
            (if (> current-speed 1)
                (bufset-u8 tx-frame 10 current-speed)
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
                ; normal single press = light
                (set 'light (bitwise-xor light 1))
            )
        )
        (if (>= presses 2)
            (if (> (get-adc-decoded 1) min-adc-brake)
                ; brake + double = lock
                (if (= unlock 0)
                    {
                        (set 'lock (bitwise-xor lock 1))
                        (set 'feedback 1)
                    }
                )
                ; double press = cycle speed modes
                (if (= (+ lock unlock) 0)
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
)

(defun handle-lock()
    (if (= lock 1)
        {
            (set-current-rel 0)
            (if (> (* (get-speed) 3.6) min-speed)
                (set-brake-rel 1)
                (set-brake-rel 0)
            )
        }
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

                ; falling edge = pressed
                (if (> buttonold button)
                    {
                        (if (= presses 0)
                            (set 'presstime (systime))
                        )
                        (set 'presses (+ presses 1))
                    }
                )

                ; rising edge = released
                (if (< buttonold button)
                    (set 'releasetime (systime))
                )

                (var held (- (systime) presstime))
                (var since-release (- (systime) releasetime))
                (var is-active (or (= off 1) (<= (get-speed) button-safety-speed)))

                ; long hold 6s = screen off
                (if (and (= button 0) (> presses 0) (> held 6000))
                    {
                        (set 'off 1)
                        (set 'light 0)
                        (set 'unlock 0)
                        (set 'feedback 1)
                        (apply-mode)
                        (reset-button)
                    }
                    ; 300ms after release = fire
                    (if (and (> presses 0) (= button 1) (> since-release 300))
                        {
                            (if is-active (handle-button))
                            (reset-button)
                        }
                    )
                )

                (set 'buttonold button)
                (handle-lock)
            }
        )
    }
)

; Apply mode on startup
(apply-mode)

(spawn 150 read-frames)
(button-logic)