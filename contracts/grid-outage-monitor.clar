;; Grid Outage Monitor Contract
;; Power grid outage detection and duration tracking for business interruption claims

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-OUTAGE-NOT-FOUND (err u201))
(define-constant ERR-INVALID-REGION (err u202))
(define-constant ERR-INVALID-SEVERITY (err u203))
(define-constant ERR-OUTAGE-ALREADY-RESOLVED (err u204))
(define-constant ERR-INVALID-DURATION (err u205))
(define-constant ERR-INSUFFICIENT-DATA (err u206))
(define-constant ERR-INVALID-OPERATOR (err u207))

;; Outage severity levels
(define-constant SEVERITY-MINOR u1)
(define-constant SEVERITY-MODERATE u2)
(define-constant SEVERITY-MAJOR u3)
(define-constant SEVERITY-CRITICAL u4)
(define-constant SEVERITY-EMERGENCY u5)

;; Time constants
(define-constant MIN-OUTAGE-DURATION u1) ;; Minimum 1 block
(define-constant MAX-OUTAGE-DURATION u8640) ;; Maximum ~60 days
(define-constant CLAIM-THRESHOLD-DURATION u6) ;; Minimum 6 blocks for claims

;; Data Variables
(define-data-var next-outage-id uint u1)
(define-data-var total-outages uint u0)
(define-data-var active-outages uint u0)
(define-data-var monitoring-fee uint u500) ;; Fee in microSTX

;; Grid operators authorized to report outages
(define-map authorized-operators
  { operator: principal }
  {
    is-active: bool,
    region-coverage: (list 20 (string-ascii 30)),
    total-reports: uint,
    accuracy-score: uint, ;; Out of 100
    last-report: uint
  }
)

;; Outage event tracking
(define-map outage-events
  { outage-id: uint }
  {
    reporter: principal,
    region: (string-ascii 30),
    affected-areas: (list 10 (string-ascii 30)),
    severity: uint,
    start-time: uint,
    end-time: (optional uint),
    duration: (optional uint),
    cause: (string-ascii 50),
    estimated-affected-capacity: uint, ;; MW
    actual-affected-capacity: (optional uint), ;; MW
    is-resolved: bool,
    resolution-notes: (optional (string-ascii 100))
  }
)

;; Regional grid statistics
(define-map regional-grid-stats
  { region: (string-ascii 30), period: uint }
  {
    total-outages: uint,
    total-outage-duration: uint,
    average-duration: uint,
    max-severity-recorded: uint,
    total-capacity-affected: uint,
    reliability-score: uint ;; Out of 100
  }
)

;; Producer impact tracking
(define-map producer-outage-impact
  { producer: principal, outage-id: uint }
  {
    estimated-loss: uint, ;; in microSTX
    actual-loss: (optional uint), ;; in microSTX
    compensation-due: uint,
    compensation-paid: bool,
    capacity-affected: uint, ;; MW
    duration-affected: uint ;; blocks
  }
)

;; Grid health monitoring
(define-map grid-health-indicators
  { region: (string-ascii 30) }
  {
    uptime-percentage: uint, ;; Out of 10000 (for 2 decimal precision)
    average-frequency: uint, ;; Hz * 1000 for precision
    voltage-stability: uint, ;; Percentage * 100
    load-factor: uint, ;; Percentage * 100
    last-maintenance: uint,
    next-scheduled-maintenance: uint
  }
)

;; Outage cause categories
(define-map outage-causes
  { cause-id: uint }
  {
    cause-name: (string-ascii 50),
    frequency: uint,
    average-duration: uint,
    average-impact: uint,
    preventable: bool
  }
)

;; Public Functions

;; Register authorized grid operator
(define-public (register-operator (operator principal) (regions (list 20 (string-ascii 30))))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> (len regions) u0) ERR-INVALID-REGION)
    
    (map-set authorized-operators
      { operator: operator }
      {
        is-active: true,
        region-coverage: regions,
        total-reports: u0,
        accuracy-score: u100,
        last-report: u0
      }
    )
    
    (ok true)
  )
)

;; Report grid outage event
(define-public (report-outage (region (string-ascii 30)) (affected-areas (list 10 (string-ascii 30))) (severity uint) (cause (string-ascii 50)) (estimated-capacity uint))
  (let
    ((outage-id (var-get next-outage-id))
     (operator-data (unwrap! (map-get? authorized-operators { operator: tx-sender }) ERR-NOT-AUTHORIZED)))
    
    ;; Validate operator authorization
    (asserts! (get is-active operator-data) ERR-NOT-AUTHORIZED)
    
    ;; Validate severity level
    (asserts! (and (>= severity SEVERITY-MINOR) (<= severity SEVERITY-EMERGENCY)) ERR-INVALID-SEVERITY)
    
    ;; Validate region coverage
    (asserts! (is-some (index-of (get region-coverage operator-data) region)) ERR-INVALID-REGION)
    
    ;; Create outage record
    (map-set outage-events
      { outage-id: outage-id }
      {
        reporter: tx-sender,
        region: region,
        affected-areas: affected-areas,
        severity: severity,
        start-time: stacks-block-height,
        end-time: none,
        duration: none,
        cause: cause,
        estimated-affected-capacity: estimated-capacity,
        actual-affected-capacity: none,
        is-resolved: false,
        resolution-notes: none
      }
    )
    
    ;; Update operator statistics
    (map-set authorized-operators
      { operator: tx-sender }
      (merge operator-data {
        total-reports: (+ (get total-reports operator-data) u1),
        last-report: stacks-block-height
      })
    )
    
    ;; Update counters
    (var-set next-outage-id (+ outage-id u1))
    (var-set total-outages (+ (var-get total-outages) u1))
    (var-set active-outages (+ (var-get active-outages) u1))
    
    (ok outage-id)
  )
)

;; Update outage status and resolution
(define-public (update-outage-status (outage-id uint) (resolved bool) (actual-capacity (optional uint)) (resolution-notes (optional (string-ascii 100))))
  (let
    ((outage-data (unwrap! (map-get? outage-events { outage-id: outage-id }) ERR-OUTAGE-NOT-FOUND)))
    
    ;; Validate reporter authorization
    (asserts! (or (is-eq tx-sender (get reporter outage-data))
                  (is-eq tx-sender CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)
    
    ;; Check if already resolved
    (asserts! (not (get is-resolved outage-data)) ERR-OUTAGE-ALREADY-RESOLVED)
    
    ;; Calculate duration if resolving
    (let
      ((end-time (if resolved (some stacks-block-height) none))
       (duration (if resolved 
                   (some (- stacks-block-height (get start-time outage-data))) 
                   none)))
      
      ;; Update outage record
      (map-set outage-events
        { outage-id: outage-id }
        (merge outage-data {
          end-time: end-time,
          duration: duration,
          actual-affected-capacity: actual-capacity,
          is-resolved: resolved,
          resolution-notes: resolution-notes
        })
      )
      
      ;; Update active outages count if resolved
      (if resolved
        (var-set active-outages (- (var-get active-outages) u1))
        true
      )
      
      (ok true)
    )
  )
)

;; Calculate financial impact of outage on producers
(define-public (calculate-impact (producer principal) (outage-id uint) (capacity-affected uint) (energy-price uint))
  (let
    ((outage-data (unwrap! (map-get? outage-events { outage-id: outage-id }) ERR-OUTAGE-NOT-FOUND))
     (duration-blocks (match (get duration outage-data)
                        duration duration
                        (- stacks-block-height (get start-time outage-data)))))
    
    ;; Only calculate impact for significant outages
    (asserts! (>= duration-blocks CLAIM-THRESHOLD-DURATION) ERR-INVALID-DURATION)
    
    ;; Calculate estimated loss (capacity * duration * price)
    (let
      ((estimated-loss (* (* capacity-affected duration-blocks) energy-price))
       (severity-multiplier (let
                               ((severity-level (get severity outage-data)))
                               (if (is-eq severity-level u1) u100
                                 (if (is-eq severity-level u2) u110
                                   (if (is-eq severity-level u3) u125
                                     (if (is-eq severity-level u4) u150
                                       (if (is-eq severity-level u5) u200
                                         u100)))))))   ;; Default: 100%
       (adjusted-loss (/ (* estimated-loss severity-multiplier) u100)))
      
      ;; Store impact calculation
      (map-set producer-outage-impact
        { producer: producer, outage-id: outage-id }
        {
          estimated-loss: adjusted-loss,
          actual-loss: none,
          compensation-due: adjusted-loss,
          compensation-paid: false,
          capacity-affected: capacity-affected,
          duration-affected: duration-blocks
        }
      )
      
      (ok adjusted-loss)
    )
  )
)

;; Update grid health indicators
(define-public (update-grid-health (region (string-ascii 30)) (uptime-pct uint) (frequency uint) (voltage-stability uint) (load-factor uint))
  (begin
    ;; Only authorized operators or owner can update
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER)
                  (is-some (map-get? authorized-operators { operator: tx-sender }))) ERR-NOT-AUTHORIZED)
    
    ;; Validate ranges
    (asserts! (<= uptime-pct u10000) ERR-INVALID-SEVERITY) ;; Max 100.00%
    (asserts! (and (>= frequency u59000) (<= frequency u61000)) ERR-INVALID-SEVERITY) ;; 59-61 Hz
    (asserts! (<= voltage-stability u10000) ERR-INVALID-SEVERITY) ;; Max 100.00%
    (asserts! (<= load-factor u10000) ERR-INVALID-SEVERITY) ;; Max 100.00%
    
    (map-set grid-health-indicators
      { region: region }
      {
        uptime-percentage: uptime-pct,
        average-frequency: frequency,
        voltage-stability: voltage-stability,
        load-factor: load-factor,
        last-maintenance: stacks-block-height,
        next-scheduled-maintenance: (+ stacks-block-height u4320) ;; ~30 days
      }
    )
    
    (ok true)
  )
)

;; Process compensation payment
(define-public (process-compensation (producer principal) (outage-id uint))
  (let
    ((impact-data (unwrap! (map-get? producer-outage-impact { producer: producer, outage-id: outage-id }) ERR-OUTAGE-NOT-FOUND)))
    
    ;; Only contract owner can process compensation
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    
    ;; Check if not already paid
    (asserts! (not (get compensation-paid impact-data)) ERR-OUTAGE-ALREADY-RESOLVED)
    
    ;; Mark as paid
    (map-set producer-outage-impact
      { producer: producer, outage-id: outage-id }
      (merge impact-data { compensation-paid: true })
    )
    
    (ok (get compensation-due impact-data))
  )
)

;; Read-only Functions

;; Get outage history for analysis
(define-read-only (get-outage-history (region (string-ascii 30)) (limit uint))
  (ok { region: region, limit: limit }) ;; Simplified - would iterate in production
)

;; Get outage event details
(define-read-only (get-outage-event (outage-id uint))
  (map-get? outage-events { outage-id: outage-id })
)

;; Get regional grid statistics
(define-read-only (get-regional-stats (region (string-ascii 30)) (period uint))
  (map-get? regional-grid-stats { region: region, period: period })
)

;; Get producer impact data
(define-read-only (get-producer-impact (producer principal) (outage-id uint))
  (map-get? producer-outage-impact { producer: producer, outage-id: outage-id })
)

;; Get grid health indicators
(define-read-only (get-grid-health (region (string-ascii 30)))
  (map-get? grid-health-indicators { region: region })
)

;; Get operator information
(define-read-only (get-operator-info (operator principal))
  (map-get? authorized-operators { operator: operator })
)

;; Get current outage statistics
(define-read-only (get-outage-stats)
  (ok {
    total-outages: (var-get total-outages),
    active-outages: (var-get active-outages),
    next-outage-id: (var-get next-outage-id)
  })
)

;; Check if outage qualifies for claims
(define-read-only (qualifies-for-claim (outage-id uint))
  (match (map-get? outage-events { outage-id: outage-id })
    outage (let
             ((duration (match (get duration outage)
                          dur dur
                          (if (get is-resolved outage)
                            (- stacks-block-height (get start-time outage))
                            u0))))
             (ok {
               qualifies: (>= duration CLAIM-THRESHOLD-DURATION),
               duration: duration,
               severity: (get severity outage)
             }))
    (ok { qualifies: false, duration: u0, severity: u0 })
  )
)

;; Calculate regional reliability score
(define-read-only (calculate-reliability-score (region (string-ascii 30)) (period uint))
  (match (map-get? regional-grid-stats { region: region, period: period })
    stats (let
            ((uptime-factor (- u10000 (* (get total-outages stats) u10)))
             (duration-penalty (* (get average-duration stats) u5))
             (severity-penalty (* (get max-severity-recorded stats) u20))
             (base-score (- u10000 (+ duration-penalty severity-penalty))))
            (ok (if (>= base-score uptime-factor) uptime-factor base-score)))
    (ok u9500) ;; Default score if no data
  )
)
