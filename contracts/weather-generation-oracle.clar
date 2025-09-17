;; Weather Generation Oracle Contract
;; Solar irradiance and wind speed data for renewable energy production forecasting

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-DATA (err u101))
(define-constant ERR-DATA-NOT-FOUND (err u102))
(define-constant ERR-INVALID-LOCATION (err u103))
(define-constant ERR-TIMESTAMP-ERROR (err u104))
(define-constant ERR-ORACLE-NOT-FOUND (err u105))
(define-constant ERR-INSUFFICIENT-READINGS (err u106))
(define-constant ERR-DATA-TOO-OLD (err u107))

;; Weather data bounds
(define-constant MAX-SOLAR-IRRADIANCE u1500) ;; W/m^2 maximum solar irradiance
(define-constant MIN-SOLAR-IRRADIANCE u0) ;; W/m^2 minimum solar irradiance
(define-constant MAX-WIND-SPEED u50) ;; m/s maximum wind speed for safety
(define-constant MIN-WIND-SPEED u0) ;; m/s minimum wind speed
(define-constant MAX-TEMPERATURE 60) ;; degrees C maximum temperature
(define-constant MIN-TEMPERATURE -40) ;; degrees C minimum temperature
(define-constant DATA-VALIDITY-PERIOD u144) ;; blocks (~24 hours with 10-minute blocks)

;; Data Variables
(define-data-var next-reading-id uint u1)
(define-data-var authorized-oracles-count uint u0)
(define-data-var data-fee uint u1000) ;; Fee in microSTX for data submission
(define-data-var minimum-oracle-consensus uint u2) ;; Minimum oracles needed for consensus

;; Oracle Management
(define-map authorized-oracles
  { oracle: principal }
  {
    is-active: bool,
    reputation-score: uint,
    total-submissions: uint,
    last-submission: uint,
    location-coverage: (list 10 (string-ascii 20))
  }
)

;; Weather Data Storage
(define-map weather-readings
  { reading-id: uint }
  {
    oracle: principal,
    location: (string-ascii 20),
    timestamp: uint,
    solar-irradiance: uint, ;; W/m^2
    wind-speed: uint, ;; m/s * 100 for precision
    temperature: int, ;; degrees C * 100 for precision
    humidity: uint, ;; percentage * 100
    cloud-coverage: uint, ;; percentage * 100
    verified: bool
  }
)

;; Location-based aggregated data
(define-map location-weather-summary
  { location: (string-ascii 20), date: uint }
  {
    avg-solar-irradiance: uint,
    avg-wind-speed: uint,
    avg-temperature: int,
    reading-count: uint,
    quality-score: uint,
    last-updated: uint
  }
)

;; Production forecasting data
(define-map energy-production-factors
  { location: (string-ascii 20) }
  {
    solar-efficiency-factor: uint, ;; percentage * 100
    wind-efficiency-factor: uint, ;; percentage * 100
    seasonal-adjustments: (list 12 uint),
    historical-average-irradiance: uint,
    historical-average-wind-speed: uint
  }
)

;; Weather alerts and thresholds
(define-map weather-alerts
  { alert-id: uint }
  {
    location: (string-ascii 20),
    alert-type: (string-ascii 30),
    severity: uint, ;; 1-5 scale
    triggered-at: uint,
    duration: uint,
    impact-forecast: uint ;; estimated production impact percentage
  }
)

;; Public Functions

;; Register authorized oracle
(define-public (register-oracle (oracle principal) (locations (list 10 (string-ascii 20))))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> (len locations) u0) ERR-INVALID-DATA)
    
    (map-set authorized-oracles
      { oracle: oracle }
      {
        is-active: true,
        reputation-score: u100,
        total-submissions: u0,
        last-submission: u0,
        location-coverage: locations
      }
    )
    
    (var-set authorized-oracles-count (+ (var-get authorized-oracles-count) u1))
    (ok true)
  )
)

;; Submit weather data from authorized oracles
(define-public (submit-weather-data (location (string-ascii 20)) (solar-irradiance uint) (wind-speed uint) (temperature int) (humidity uint) (cloud-coverage uint))
  (let
    ((reading-id (var-get next-reading-id))
     (oracle-data (unwrap! (map-get? authorized-oracles { oracle: tx-sender }) ERR-NOT-AUTHORIZED)))
    
    ;; Validate oracle authorization and active status
    (asserts! (get is-active oracle-data) ERR-NOT-AUTHORIZED)
    
    ;; Validate data bounds
    (asserts! (and (>= solar-irradiance MIN-SOLAR-IRRADIANCE) (<= solar-irradiance MAX-SOLAR-IRRADIANCE)) ERR-INVALID-DATA)
    (asserts! (and (>= wind-speed MIN-WIND-SPEED) (<= wind-speed MAX-WIND-SPEED)) ERR-INVALID-DATA)
    (asserts! (and (>= temperature MIN-TEMPERATURE) (<= temperature MAX-TEMPERATURE)) ERR-INVALID-DATA)
    (asserts! (and (>= humidity u0) (<= humidity u10000)) ERR-INVALID-DATA) ;; 0-100% * 100
    (asserts! (and (>= cloud-coverage u0) (<= cloud-coverage u10000)) ERR-INVALID-DATA) ;; 0-100% * 100
    
    ;; Store weather reading
    (map-set weather-readings
      { reading-id: reading-id }
      {
        oracle: tx-sender,
        location: location,
        timestamp: stacks-block-height,
        solar-irradiance: solar-irradiance,
        wind-speed: wind-speed,
        temperature: temperature,
        humidity: humidity,
        cloud-coverage: cloud-coverage,
        verified: false
      }
    )
    
    ;; Update oracle statistics
    (map-set authorized-oracles
      { oracle: tx-sender }
      (merge oracle-data {
        total-submissions: (+ (get total-submissions oracle-data) u1),
        last-submission: stacks-block-height
      })
    )
    
    (var-set next-reading-id (+ reading-id u1))
    (ok reading-id)
  )
)

;; Calculate solar irradiance factor for production estimation
(define-public (calculate-irradiance-factor (location (string-ascii 20)) (reading-id uint))
  (let
    ((weather-data (unwrap! (map-get? weather-readings { reading-id: reading-id }) ERR-DATA-NOT-FOUND))
     (production-factors (map-get? energy-production-factors { location: location })))
    
    ;; Validate location matches
    (asserts! (is-eq (get location weather-data) location) ERR-INVALID-LOCATION)
    
    ;; Calculate production factor based on irradiance and cloud coverage
    (let
      ((irradiance (get solar-irradiance weather-data))
       (cloud-factor (- u10000 (get cloud-coverage weather-data))) ;; Invert cloud coverage
       (base-factor (/ (* irradiance cloud-factor) u10000)))
      
      (match production-factors
        factors (let
                  ((efficiency (get solar-efficiency-factor factors))
                   (adjusted-factor (/ (* base-factor efficiency) u10000)))
                  (ok adjusted-factor))
        (ok base-factor)
      )
    )
  )
)

;; Update production efficiency factors
(define-public (update-production-factors (location (string-ascii 20)) (solar-efficiency uint) (wind-efficiency uint) (avg-irradiance uint) (avg-wind-speed uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (and (<= solar-efficiency u10000) (<= wind-efficiency u10000)) ERR-INVALID-DATA)
    
    (map-set energy-production-factors
      { location: location }
      {
        solar-efficiency-factor: solar-efficiency,
        wind-efficiency-factor: wind-efficiency,
        seasonal-adjustments: (list u10000 u10000 u10000 u10000 u10000 u10000 u10000 u10000 u10000 u10000 u10000 u10000),
        historical-average-irradiance: avg-irradiance,
        historical-average-wind-speed: avg-wind-speed
      }
    )
    
    (ok true)
  )
)

;; Verify weather reading (consensus mechanism)
(define-public (verify-weather-reading (reading-id uint) (verified bool))
  (let
    ((reading-data (unwrap! (map-get? weather-readings { reading-id: reading-id }) ERR-DATA-NOT-FOUND)))
    
    ;; Only contract owner or authorized oracles can verify
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER)
                  (is-some (map-get? authorized-oracles { oracle: tx-sender }))) ERR-NOT-AUTHORIZED)
    
    ;; Update verification status
    (map-set weather-readings
      { reading-id: reading-id }
      (merge reading-data { verified: verified })
    )
    
    (ok true)
  )
)

;; Create weather alert
(define-public (create-weather-alert (location (string-ascii 20)) (alert-type (string-ascii 30)) (severity uint) (duration uint) (impact-forecast uint))
  (let
    ((alert-id (var-get next-reading-id))) ;; Reuse ID counter
    
    ;; Only authorized oracles or owner can create alerts
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER)
                  (is-some (map-get? authorized-oracles { oracle: tx-sender }))) ERR-NOT-AUTHORIZED)
    
    ;; Validate severity and impact ranges
    (asserts! (and (>= severity u1) (<= severity u5)) ERR-INVALID-DATA)
    (asserts! (<= impact-forecast u10000) ERR-INVALID-DATA)
    
    (map-set weather-alerts
      { alert-id: alert-id }
      {
        location: location,
        alert-type: alert-type,
        severity: severity,
        triggered-at: stacks-block-height,
        duration: duration,
        impact-forecast: impact-forecast
      }
    )
    
    (ok alert-id)
  )
)

;; Read-only Functions

;; Get wind speed data for a specific location and timeframe
(define-read-only (get-wind-speed-data (location (string-ascii 20)) (start-block uint) (end-block uint))
  (ok { location: location, start: start-block, end: end-block }) ;; Simplified - would iterate in production
)

;; Validate weather reading authenticity and bounds
(define-read-only (validate-weather-reading (reading-id uint))
  (let
    ((reading (map-get? weather-readings { reading-id: reading-id })))
    (match reading
      data (let
             ((age (- stacks-block-height (get timestamp data)))
              (irradiance-valid (and (>= (get solar-irradiance data) MIN-SOLAR-IRRADIANCE) 
                                   (<= (get solar-irradiance data) MAX-SOLAR-IRRADIANCE)))
              (wind-valid (and (>= (get wind-speed data) MIN-WIND-SPEED) 
                             (<= (get wind-speed data) MAX-WIND-SPEED)))
              (temp-valid (and (>= (get temperature data) MIN-TEMPERATURE) 
                             (<= (get temperature data) MAX-TEMPERATURE))))
             (ok {
               is-valid: (and irradiance-valid wind-valid temp-valid),
               is-fresh: (< age DATA-VALIDITY-PERIOD),
               is-verified: (get verified data)
             }))
      (ok { is-valid: false, is-fresh: false, is-verified: false })
    )
  )
)

;; Get weather reading by ID
(define-read-only (get-weather-reading (reading-id uint))
  (map-get? weather-readings { reading-id: reading-id })
)

;; Get oracle information
(define-read-only (get-oracle-info (oracle principal))
  (map-get? authorized-oracles { oracle: oracle })
)

;; Get location weather summary
(define-read-only (get-location-summary (location (string-ascii 20)) (date uint))
  (map-get? location-weather-summary { location: location, date: date })
)

;; Get production factors for location
(define-read-only (get-production-factors (location (string-ascii 20)))
  (map-get? energy-production-factors { location: location })
)

;; Get weather alert
(define-read-only (get-weather-alert (alert-id uint))
  (map-get? weather-alerts { alert-id: alert-id })
)

;; Get next reading ID
(define-read-only (get-next-reading-id)
  (var-get next-reading-id)
)

;; Check if oracle is authorized
(define-read-only (is-oracle-authorized (oracle principal))
  (match (map-get? authorized-oracles { oracle: oracle })
    oracle-data (get is-active oracle-data)
    false
  )
)
