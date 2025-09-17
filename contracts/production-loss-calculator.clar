;; Production Loss Calculator Contract
;; Automated calculation and processing of energy production loss claims

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-PRODUCER-NOT-FOUND (err u301))
(define-constant ERR-INVALID-CAPACITY (err u302))
(define-constant ERR-INVALID-CLAIM (err u303))
(define-constant ERR-CLAIM-NOT-FOUND (err u304))
(define-constant ERR-CLAIM-ALREADY-PROCESSED (err u305))
(define-constant ERR-INSUFFICIENT-COVERAGE (err u306))
(define-constant ERR-INVALID-PRODUCTION-DATA (err u307))
(define-constant ERR-POLICY-EXPIRED (err u308))
(define-constant ERR-PAYOUT-FAILED (err u309))

;; Production and claim constants
(define-constant MIN-CAPACITY u1) ;; Minimum 1 MW capacity
(define-constant MAX-CAPACITY u10000) ;; Maximum 10,000 MW capacity
(define-constant MIN-CLAIM-AMOUNT u1000) ;; Minimum claim 1000 microSTX
(define-constant MAX-CLAIM-AMOUNT u100000000) ;; Maximum claim 100 STX
(define-constant CLAIM-PROCESSING-FEE u500) ;; Processing fee in microSTX
(define-constant POLICY-DURATION u52560) ;; Policy duration ~1 year in blocks

;; Data Variables
(define-data-var next-producer-id uint u1)
(define-data-var next-claim-id uint u1)
(define-data-var total-claims-processed uint u0)
(define-data-var total-payouts uint u0)
(define-data-var insurance-fund uint u0)
(define-data-var base-premium-rate uint u100) ;; Base premium rate per MW per block

;; Energy producer registration
(define-map energy-producers
  { producer-id: uint }
  {
    owner: principal,
    name: (string-ascii 50),
    energy-type: (string-ascii 20), ;; "solar", "wind", "hydro", etc.
    location: (string-ascii 30),
    installed-capacity: uint, ;; MW
    efficiency-rating: uint, ;; Percentage * 100
    registration-date: uint,
    is-active: bool,
    total-production: uint, ;; MWh
    claims-history: uint
  }
)

;; Insurance policies
(define-map producer-policies
  { producer-id: uint, policy-period: uint }
  {
    premium-paid: uint,
    coverage-amount: uint,
    deductible: uint,
    policy-start: uint,
    policy-end: uint,
    weather-coverage: bool,
    grid-outage-coverage: bool,
    equipment-coverage: bool,
    is-active: bool
  }
)

;; Production data tracking
(define-map production-records
  { producer-id: uint, period: uint }
  {
    expected-production: uint, ;; MWh
    actual-production: uint, ;; MWh
    weather-factor: uint, ;; Impact factor * 100
    grid-availability: uint, ;; Percentage * 100
    equipment-uptime: uint, ;; Percentage * 100
    recorded-date: uint,
    verified: bool
  }
)

;; Loss claims
(define-map loss-claims
  { claim-id: uint }
  {
    producer-id: uint,
    claim-type: (string-ascii 30), ;; "weather", "outage", "equipment"
    loss-period-start: uint,
    loss-period-end: uint,
    expected-production: uint, ;; MWh
    actual-production: uint, ;; MWh
    production-loss: uint, ;; MWh
    energy-price: uint, ;; microSTX per MWh
    claimed-amount: uint, ;; microSTX
    calculated-payout: uint, ;; microSTX
    is-approved: bool,
    is-paid: bool,
    submitted-date: uint,
    processed-date: (optional uint),
    evidence-hash: (buff 32)
  }
)

;; Payout processing
(define-map claim-payouts
  { claim-id: uint }
  {
    recipient: principal,
    amount: uint,
    processing-fee: uint,
    net-payout: uint,
    payout-date: uint,
    transaction-id: (optional (buff 32))
  }
)

;; Energy pricing data
(define-map energy-market-prices
  { location: (string-ascii 30), date: uint }
  {
    solar-price: uint, ;; microSTX per MWh
    wind-price: uint, ;; microSTX per MWh
    base-price: uint, ;; microSTX per MWh
    peak-multiplier: uint, ;; Multiplier * 100
    demand-factor: uint ;; Demand adjustment * 100
  }
)

;; Risk assessment data
(define-map producer-risk-profiles
  { producer-id: uint }
  {
    weather-risk-score: uint, ;; 1-100 scale
    grid-risk-score: uint, ;; 1-100 scale
    equipment-risk-score: uint, ;; 1-100 scale
    location-risk-multiplier: uint, ;; Multiplier * 100
    historical-claim-frequency: uint,
    risk-tier: uint ;; 1-5 tier system
  }
)

;; Public Functions

;; Register energy producer
(define-public (register-producer (name (string-ascii 50)) (energy-type (string-ascii 20)) (location (string-ascii 30)) (capacity uint) (efficiency uint))
  (let
    ((producer-id (var-get next-producer-id)))
    
    ;; Validate input parameters
    (asserts! (> (len name) u0) ERR-INVALID-CAPACITY)
    (asserts! (and (>= capacity MIN-CAPACITY) (<= capacity MAX-CAPACITY)) ERR-INVALID-CAPACITY)
    (asserts! (and (>= efficiency u0) (<= efficiency u10000)) ERR-INVALID-CAPACITY) ;; 0-100%
    
    ;; Create producer record
    (map-set energy-producers
      { producer-id: producer-id }
      {
        owner: tx-sender,
        name: name,
        energy-type: energy-type,
        location: location,
        installed-capacity: capacity,
        efficiency-rating: efficiency,
        registration-date: stacks-block-height,
        is-active: true,
        total-production: u0,
        claims-history: u0
      }
    )
    
    (var-set next-producer-id (+ producer-id u1))
    (ok producer-id)
  )
)

;; Calculate expected production based on conditions
(define-public (calculate-expected-production (producer-id uint) (weather-factor uint) (grid-availability uint) (period-duration uint))
  (let
    ((producer-data (unwrap! (map-get? energy-producers { producer-id: producer-id }) ERR-PRODUCER-NOT-FOUND)))
    
    ;; Validate producer ownership
    (asserts! (is-eq (get owner producer-data) tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Calculate base production potential
    (let
      ((base-capacity (get installed-capacity producer-data))
       (efficiency (get efficiency-rating producer-data))
       (weather-adjusted (* base-capacity (/ weather-factor u10000)))
       (grid-adjusted (* weather-adjusted (/ grid-availability u10000)))
       (efficiency-adjusted (* grid-adjusted (/ efficiency u10000)))
       (period-adjusted (* efficiency-adjusted period-duration)))
      
      ;; Store production record
      (map-set production-records
        { producer-id: producer-id, period: stacks-block-height }
        {
          expected-production: period-adjusted,
          actual-production: u0, ;; To be updated later
          weather-factor: weather-factor,
          grid-availability: grid-availability,
          equipment-uptime: u10000, ;; Default 100%
          recorded-date: stacks-block-height,
          verified: false
        }
      )
      
      (ok period-adjusted)
    )
  )
)

;; Process loss claim automatically
(define-public (process-loss-claim (producer-id uint) (claim-type (string-ascii 30)) (loss-start uint) (loss-end uint) (actual-production uint) (energy-price uint) (evidence-hash (buff 32)))
  (let
    ((claim-id (var-get next-claim-id))
     (producer-data (unwrap! (map-get? energy-producers { producer-id: producer-id }) ERR-PRODUCER-NOT-FOUND))
     (production-data (map-get? production-records { producer-id: producer-id, period: loss-start })))
    
    ;; Validate producer ownership
    (asserts! (is-eq (get owner producer-data) tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Validate claim type
    (asserts! (or (is-eq claim-type "weather") 
                  (is-eq claim-type "outage") 
                  (is-eq claim-type "equipment")) ERR-INVALID-CLAIM)
    
    ;; Calculate loss and claim amount
    (let
      ((expected-production (match production-data
                             data (get expected-production data)
                             (* (get installed-capacity producer-data) (- loss-end loss-start))))
       (production-loss (if (> expected-production actual-production)
                          (- expected-production actual-production)
                          u0))
       (claimed-amount (* production-loss energy-price))
       (calculated-payout (calculate-payout-amount producer-id claimed-amount claim-type)))
      
      ;; Validate claim amount
      (asserts! (and (>= claimed-amount MIN-CLAIM-AMOUNT) (<= claimed-amount MAX-CLAIM-AMOUNT)) ERR-INVALID-CLAIM)
      
      ;; Create claim record
      (map-set loss-claims
        { claim-id: claim-id }
        {
          producer-id: producer-id,
          claim-type: claim-type,
          loss-period-start: loss-start,
          loss-period-end: loss-end,
          expected-production: expected-production,
          actual-production: actual-production,
          production-loss: production-loss,
          energy-price: energy-price,
          claimed-amount: claimed-amount,
          calculated-payout: calculated-payout,
          is-approved: true, ;; Auto-approve valid claims
          is-paid: false,
          submitted-date: stacks-block-height,
          processed-date: (some stacks-block-height),
          evidence-hash: evidence-hash
        }
      )
      
      ;; Update producer claims history
      (map-set energy-producers
        { producer-id: producer-id }
        (merge producer-data {
          claims-history: (+ (get claims-history producer-data) u1)
        })
      )
      
      (var-set next-claim-id (+ claim-id u1))
      (var-set total-claims-processed (+ (var-get total-claims-processed) u1))
      
      (ok { claim-id: claim-id, payout-amount: calculated-payout })
    )
  )
)

;; Distribute payout to affected producers
(define-public (distribute-payout (claim-id uint))
  (let
    ((claim-data (unwrap! (map-get? loss-claims { claim-id: claim-id }) ERR-CLAIM-NOT-FOUND))
     (producer-data (unwrap! (map-get? energy-producers { producer-id: (get producer-id claim-data) }) ERR-PRODUCER-NOT-FOUND)))
    
    ;; Validate claim is approved and not paid
    (asserts! (get is-approved claim-data) ERR-INVALID-CLAIM)
    (asserts! (not (get is-paid claim-data)) ERR-CLAIM-ALREADY-PROCESSED)
    
    ;; Only contract owner can distribute payouts
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    
    ;; Check insurance fund has sufficient balance
    (let
      ((payout-amount (get calculated-payout claim-data))
       (net-payout (- payout-amount CLAIM-PROCESSING-FEE)))
      
      (asserts! (>= (var-get insurance-fund) payout-amount) ERR-INSUFFICIENT-COVERAGE)
      
      ;; Record payout
      (map-set claim-payouts
        { claim-id: claim-id }
        {
          recipient: (get owner producer-data),
          amount: payout-amount,
          processing-fee: CLAIM-PROCESSING-FEE,
          net-payout: net-payout,
          payout-date: stacks-block-height,
          transaction-id: none
        }
      )
      
      ;; Mark claim as paid
      (map-set loss-claims
        { claim-id: claim-id }
        (merge claim-data { is-paid: true })
      )
      
      ;; Update insurance fund and totals
      (var-set insurance-fund (- (var-get insurance-fund) payout-amount))
      (var-set total-payouts (+ (var-get total-payouts) payout-amount))
      
      (ok net-payout)
    )
  )
)

;; Update energy market prices
(define-public (update-market-prices (location (string-ascii 30)) (solar-price uint) (wind-price uint) (base-price uint) (peak-multiplier uint))
  (begin
    ;; Only contract owner can update prices
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    
    (map-set energy-market-prices
      { location: location, date: stacks-block-height }
      {
        solar-price: solar-price,
        wind-price: wind-price,
        base-price: base-price,
        peak-multiplier: peak-multiplier,
        demand-factor: u10000 ;; Default 100%
      }
    )
    
    (ok true)
  )
)

;; Purchase insurance policy
(define-public (purchase-policy (producer-id uint) (coverage-amount uint) (deductible uint) (weather-coverage bool) (grid-coverage bool) (equipment-coverage bool))
  (let
    ((producer-data (unwrap! (map-get? energy-producers { producer-id: producer-id }) ERR-PRODUCER-NOT-FOUND))
     (premium-amount (calculate-premium producer-id coverage-amount)))
    
    ;; Validate producer ownership
    (asserts! (is-eq (get owner producer-data) tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Validate coverage amount
    (asserts! (and (>= coverage-amount MIN-CLAIM-AMOUNT) (<= coverage-amount MAX-CLAIM-AMOUNT)) ERR-INVALID-CLAIM)
    
    ;; Create policy
    (map-set producer-policies
      { producer-id: producer-id, policy-period: stacks-block-height }
      {
        premium-paid: premium-amount,
        coverage-amount: coverage-amount,
        deductible: deductible,
        policy-start: stacks-block-height,
        policy-end: (+ stacks-block-height POLICY-DURATION),
        weather-coverage: weather-coverage,
        grid-outage-coverage: grid-coverage,
        equipment-coverage: equipment-coverage,
        is-active: true
      }
    )
    
    ;; Add premium to insurance fund
    (var-set insurance-fund (+ (var-get insurance-fund) premium-amount))
    
    (ok premium-amount)
  )
)

;; Read-only Functions

;; Get producer information
(define-read-only (get-producer-info (producer-id uint))
  (map-get? energy-producers { producer-id: producer-id })
)

;; Get production record
(define-read-only (get-production-record (producer-id uint) (period uint))
  (map-get? production-records { producer-id: producer-id, period: period })
)

;; Get loss claim details
(define-read-only (get-loss-claim (claim-id uint))
  (map-get? loss-claims { claim-id: claim-id })
)

;; Get payout information
(define-read-only (get-payout-info (claim-id uint))
  (map-get? claim-payouts { claim-id: claim-id })
)

;; Get policy information
(define-read-only (get-policy-info (producer-id uint) (policy-period uint))
  (map-get? producer-policies { producer-id: producer-id, policy-period: policy-period })
)

;; Get market prices
(define-read-only (get-market-prices (location (string-ascii 30)) (date uint))
  (map-get? energy-market-prices { location: location, date: date })
)

;; Get system statistics
(define-read-only (get-system-stats)
  (ok {
    total-claims: (var-get total-claims-processed),
    total-payouts: (var-get total-payouts),
    insurance-fund: (var-get insurance-fund),
    next-claim-id: (var-get next-claim-id)
  })
)

;; Check claim eligibility
(define-read-only (check-claim-eligibility (producer-id uint) (claim-type (string-ascii 30)))
  (let
    ((producer-data (map-get? energy-producers { producer-id: producer-id })))
    (match producer-data
      producer (let
                 ((has-active-policy (is-some (map-get? producer-policies { producer-id: producer-id, policy-period: stacks-block-height })))
                  (is-active (get is-active producer)))
                 (ok {
                   eligible: (and has-active-policy is-active),
                   producer-active: is-active,
                   policy-active: has-active-policy
                 }))
      (ok { eligible: false, producer-active: false, policy-active: false })
    )
  )
)

;; Private Functions

;; Calculate premium for insurance policy
(define-private (calculate-premium (producer-id uint) (coverage-amount uint))
  (let
    ((producer-data (unwrap-panic (map-get? energy-producers { producer-id: producer-id })))
     (base-rate (var-get base-premium-rate))
     (capacity (get installed-capacity producer-data))
     (claims-history (get claims-history producer-data))
     (history-multiplier (+ u100 (* claims-history u10))) ;; 10% increase per claim
     (capacity-factor (/ (* capacity u100) u1000)) ;; Scale by capacity
     (coverage-factor (/ coverage-amount u1000000))) ;; Scale by coverage
    
    (/ (* (* (* base-rate history-multiplier) capacity-factor) coverage-factor) u10000)
  )
)

;; Calculate payout amount based on claim type and coverage
(define-private (calculate-payout-amount (producer-id uint) (claimed-amount uint) (claim-type (string-ascii 30)))
  (let
    ((policy-data (map-get? producer-policies { producer-id: producer-id, policy-period: stacks-block-height })))
    (match policy-data
      policy (let
               ((coverage-amount (get coverage-amount policy))
                (deductible (get deductible policy))
                (has-coverage (if (is-eq claim-type "weather")
                                (get weather-coverage policy)
                                (if (is-eq claim-type "outage")
                                  (get grid-outage-coverage policy)
                                  (get equipment-coverage policy))))
                (eligible-amount (if (> claimed-amount deductible)
                                  (- claimed-amount deductible)
                                  u0))
                (final-amount (if (> eligible-amount coverage-amount)
                               coverage-amount
                               eligible-amount)))
               (if has-coverage final-amount u0))
      u0 ;; No policy found
    )
  )
)
