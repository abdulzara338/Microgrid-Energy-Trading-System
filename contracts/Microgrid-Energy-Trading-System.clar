;; Storage
(define-map energy-producers
    principal
    {
        energy: uint,
        price-per-unit: uint,
    }
)
(define-map energy-trades
    {
        seller: principal,
        trade-id: uint,
    }
    {
        buyer: principal,
        amount: uint,
        price: uint,
        status: (string-ascii 20),
    }
)
(define-data-var trade-nonce uint u0)
(define-data-var min-energy-amount uint u1)
(define-data-var max-energy-amount uint u1000)

;; Constants
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-INVALID-AMOUNT (err u101))
(define-constant ERR-INSUFFICIENT-BALANCE (err u102))
(define-constant ERR-TRADE-NOT-FOUND (err u103))
(define-constant ERR-INVALID-STATUS (err u104))
(define-constant CONTRACT-OWNER tx-sender)

;; Core Functions
(define-public (register-producer
        (energy uint)
        (price-per-unit uint)
    )
    (begin
        (asserts! (> energy u0) ERR-INVALID-AMOUNT)
        (asserts! (> price-per-unit u0) ERR-INVALID-AMOUNT)
        (ok (map-set energy-producers tx-sender {
            energy: energy,
            price-per-unit: price-per-unit,
        }))
    )
)

(define-public (update-energy-amount (new-amount uint))
    (let ((producer-data (unwrap! (map-get? energy-producers tx-sender) ERR-UNAUTHORIZED)))
        (begin
            (asserts!
                (and (>= new-amount (var-get min-energy-amount)) (<= new-amount (var-get max-energy-amount)))
                ERR-INVALID-AMOUNT
            )
            (ok (map-set energy-producers tx-sender
                (merge producer-data { energy: new-amount })
            ))
        )
    )
)

(define-public (create-trade
        (seller principal)
        (amount uint)
    )
    (let (
            (producer-data (unwrap! (map-get? energy-producers seller) ERR-UNAUTHORIZED))
            (total-price (* amount (get price-per-unit producer-data)))
            (trade-id (+ (var-get trade-nonce) u1))
        )
        (begin
            (asserts! (<= amount (get energy producer-data))
                ERR-INSUFFICIENT-BALANCE
            )
            (var-set trade-nonce trade-id)
            (ok (map-set energy-trades {
                seller: seller,
                trade-id: trade-id,
            } {
                buyer: tx-sender,
                amount: amount,
                price: total-price,
                status: "pending",
            }))
        )
    )
)

(define-public (accept-trade
        (trade-id uint)
        (seller principal)
    )
    (let (
            (trade (unwrap!
                (map-get? energy-trades {
                    seller: seller,
                    trade-id: trade-id,
                })
                ERR-TRADE-NOT-FOUND
            ))
            (price (get price trade))
        )
        (begin
            (asserts! (is-eq (get status trade) "pending") ERR-INVALID-STATUS)
            (try! (stx-transfer? price tx-sender seller))
            (map-set energy-trades {
                seller: seller,
                trade-id: trade-id,
            }
                (merge trade { status: "completed" })
            )
            (ok true)
        )
    )
)

(define-public (cancel-trade (trade-id uint))
    (let ((trade (unwrap!
            (map-get? energy-trades {
                seller: tx-sender,
                trade-id: trade-id,
            })
            ERR-TRADE-NOT-FOUND
        )))
        (begin
            (asserts! (is-eq (get status trade) "pending") ERR-INVALID-STATUS)
            (ok (map-set energy-trades {
                seller: tx-sender,
                trade-id: trade-id,
            }
                (merge trade { status: "cancelled" })
            ))
        )
    )
)

;; Getter Functions
(define-read-only (get-producer-info (producer principal))
    (map-get? energy-producers producer)
)

(define-read-only (get-trade-info
        (seller principal)
        (trade-id uint)
    )
    (map-get? energy-trades {
        seller: seller,
        trade-id: trade-id,
    })
)

(define-read-only (get-current-trade-nonce)
    (ok (var-get trade-nonce))
)

;; Admin Functions
(define-public (set-energy-limits
        (new-min uint)
        (new-max uint)
    )
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (asserts! (< new-min new-max) ERR-INVALID-AMOUNT)
        (var-set min-energy-amount new-min)
        (var-set max-energy-amount new-max)
        (ok true)
    )
)
(define-map energy-escrow
    {
        seller: principal,
        trade-id: uint,
    }
    {
        amount: uint,
        locked-at: uint,
    }
)

(define-map energy-balances
    principal
    uint
)

(define-public (lock-energy-for-trade
        (seller principal)
        (trade-id uint)
        (amount uint)
    )
    (let (
            (current-balance (default-to u0 (map-get? energy-balances seller)))
            (producer-data (unwrap! (map-get? energy-producers seller) ERR-UNAUTHORIZED))
        )
        (begin
            (asserts! (>= (get energy producer-data) amount)
                ERR-INSUFFICIENT-BALANCE
            )
            (map-set energy-producers seller
                (merge producer-data { energy: (- (get energy producer-data) amount) })
            )
            (map-set energy-escrow {
                seller: seller,
                trade-id: trade-id,
            } {
                amount: amount,
                locked-at: burn-block-height,
            })
            (ok true)
        )
    )
)

(define-public (release-escrowed-energy
        (seller principal)
        (buyer principal)
        (trade-id uint)
    )
    (let (
            (escrow-data (unwrap!
                (map-get? energy-escrow {
                    seller: seller,
                    trade-id: trade-id,
                })
                ERR-TRADE-NOT-FOUND
            ))
            (current-buyer-balance (default-to u0 (map-get? energy-balances buyer)))
        )
        (begin
            (map-set energy-balances buyer
                (+ current-buyer-balance (get amount escrow-data))
            )
            (map-delete energy-escrow {
                seller: seller,
                trade-id: trade-id,
            })
            (ok true)
        )
    )
)

(define-public (return-escrowed-energy
        (seller principal)
        (trade-id uint)
    )
    (let (
            (escrow-data (unwrap!
                (map-get? energy-escrow {
                    seller: seller,
                    trade-id: trade-id,
                })
                ERR-TRADE-NOT-FOUND
            ))
            (producer-data (unwrap! (map-get? energy-producers seller) ERR-UNAUTHORIZED))
        )
        (begin
            (map-set energy-producers seller
                (merge producer-data { energy: (+ (get energy producer-data) (get amount escrow-data)) })
            )
            (map-delete energy-escrow {
                seller: seller,
                trade-id: trade-id,
            })
            (ok true)
        )
    )
)

(define-read-only (get-energy-balance (user principal))
    (default-to u0 (map-get? energy-balances user))
)

(define-read-only (get-escrow-info
        (seller principal)
        (trade-id uint)
    )
    (map-get? energy-escrow {
        seller: seller,
        trade-id: trade-id,
    })
)
(define-map price-history
    uint
    {
        timestamp: uint,
        average-price: uint,
        total-volume: uint,
        trade-count: uint,
    }
)

(define-map daily-market-stats
    uint
    {
        min-price: uint,
        max-price: uint,
        total-trades: uint,
        total-volume: uint,
    }
)

(define-data-var price-history-index uint u0)
(define-data-var total-market-volume uint u0)
(define-data-var total-market-trades uint u0)

(define-public (record-trade-data
        (price-per-unit uint)
        (volume uint)
    )
    (let (
            (current-index (var-get price-history-index))
            (new-index (+ current-index u1))
            (current-day (/ burn-block-height u144))
            (current-stats (default-to {
                min-price: price-per-unit,
                max-price: price-per-unit,
                total-trades: u0,
                total-volume: u0,
            }
                (map-get? daily-market-stats current-day)
            ))
        )
        (begin
            (var-set price-history-index new-index)
            (var-set total-market-volume (+ (var-get total-market-volume) volume))
            (var-set total-market-trades (+ (var-get total-market-trades) u1))
            (map-set price-history new-index {
                timestamp: burn-block-height,
                average-price: price-per-unit,
                total-volume: volume,
                trade-count: u1,
            })
            (map-set daily-market-stats current-day {
                min-price: (if (< price-per-unit (get min-price current-stats))
                    price-per-unit
                    (get min-price current-stats)
                ),
                max-price: (if (> price-per-unit (get max-price current-stats))
                    price-per-unit
                    (get max-price current-stats)
                ),
                total-trades: (+ (get total-trades current-stats) u1),
                total-volume: (+ (get total-volume current-stats) volume),
            })
            (ok true)
        )
    )
)

(define-public (suggest-market-price (energy-amount uint))
    (let (
            (avg-data (get-recent-average-price))
            (recent-trades (if (> (get count avg-data) u0)
                (/ (get total-price avg-data) (get count avg-data))
                u0
            ))
            (market-factor (if (> energy-amount u100)
                u95
                u105
            ))
        )
        (ok (/ (* recent-trades market-factor) u100))
    )
)

(define-read-only (get-recent-average-price)
    (let (
            (current-index (var-get price-history-index))
            (lookback-start (if (> current-index u10)
                (- current-index u10)
                u1
            ))
        )
        (fold calculate-average-helper (list u1 u2 u3 u4 u5 u6 u7 u8 u9 u10) {
            total-price: u0,
            count: u0,
            start-index: lookback-start,
            current-index: current-index,
        })
    )
)

(define-private (calculate-average-helper
        (offset uint)
        (acc {
            total-price: uint,
            count: uint,
            start-index: uint,
            current-index: uint,
        })
    )
    (let (
            (index (+ (get start-index acc) offset))
            (trade-data (map-get? price-history index))
        )
        (if (and (<= index (get current-index acc)) (is-some trade-data))
            {
                total-price: (+ (get total-price acc)
                    (get average-price (unwrap-panic trade-data))
                ),
                count: (+ (get count acc) u1),
                start-index: (get start-index acc),
                current-index: (get current-index acc),
            }
            acc
        )
    )
)

(define-read-only (get-market-summary)
    (let (
            (avg-data (get-recent-average-price))
            (current-day (/ burn-block-height u144))
            (daily-stats (map-get? daily-market-stats current-day))
        )
        {
            average-price: (if (> (get count avg-data) u0)
                (/ (get total-price avg-data) (get count avg-data))
                u0
            ),
            total-volume: (var-get total-market-volume),
            total-trades: (var-get total-market-trades),
            daily-stats: daily-stats,
        }
    )
)

(define-read-only (get-price-history-entry (index uint))
    (map-get? price-history index)
)

(define-read-only (get-daily-stats (day uint))
    (map-get? daily-market-stats day)
)

(define-map demand-metrics
    uint
    {
        total-demand: uint,
        fulfilled-demand: uint,
        pending-trades: uint,
        timestamp: uint,
    }
)

(define-data-var demand-index uint u0)
(define-data-var base-price uint u50)
(define-data-var price-volatility-factor uint u10)

(define-public (calculate-dynamic-price (energy-amount uint))
    (let (
            (total-supply (get-total-available-supply))
            (current-demand (get-current-market-demand))
            (supply-demand-ratio (if (> current-demand u0)
                (/ (* total-supply u100) current-demand)
                u100
            ))
            (volatility-adjustment (if (< supply-demand-ratio u80)
                (+ (var-get price-volatility-factor) u5)
                (if (> supply-demand-ratio u120)
                    (- (var-get price-volatility-factor) u5)
                    (var-get price-volatility-factor)
                )
            ))
            (market-price (+ (var-get base-price) volatility-adjustment))
            (volume-discount (if (> energy-amount u500)
                u95
                (if (> energy-amount u100)
                    u98
                    u100
                )
            ))
        )
        (ok (/ (* market-price volume-discount) u100))
    )
)

(define-public (update-demand-metrics
        (demand uint)
        (fulfilled uint)
        (pending uint)
    )
    (let ((new-index (+ (var-get demand-index) u1)))
        (begin
            (var-set demand-index new-index)
            (map-set demand-metrics new-index {
                total-demand: demand,
                fulfilled-demand: fulfilled,
                pending-trades: pending,
                timestamp: burn-block-height,
            })
            (ok true)
        )
    )
)

(define-public (enable-dynamic-pricing (producer principal))
    (let ((producer-data (unwrap! (map-get? energy-producers producer) ERR-UNAUTHORIZED)))
        (begin
            (asserts! (is-eq tx-sender producer) ERR-UNAUTHORIZED)
            (let ((new-price (unwrap! (calculate-dynamic-price (get energy producer-data))
                    ERR-INVALID-AMOUNT
                )))
                (ok (map-set energy-producers producer
                    (merge producer-data { price-per-unit: new-price })
                ))
            )
        )
    )
)

(define-read-only (get-total-available-supply)
    (fold sum-supply-helper (list u1 u2 u3 u4 u5 u6 u7 u8 u9 u10) u0)
)

(define-read-only (get-current-market-demand)
    (let (
            (current-index (var-get demand-index))
            (recent-metrics (map-get? demand-metrics current-index))
        )
        (if (is-some recent-metrics)
            (get total-demand (unwrap-panic recent-metrics))
            u0
        )
    )
)

(define-private (sum-supply-helper
        (item uint)
        (acc uint)
    )
    acc
)

(define-public (set-pricing-parameters
        (new-base-price uint)
        (new-volatility-factor uint)
    )
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (asserts! (> new-base-price u0) ERR-INVALID-AMOUNT)
        (asserts! (<= new-volatility-factor u50) ERR-INVALID-AMOUNT)
        (var-set base-price new-base-price)
        (var-set price-volatility-factor new-volatility-factor)
        (ok true)
    )
)

(define-read-only (get-pricing-parameters)
    {
        base-price: (var-get base-price),
        volatility-factor: (var-get price-volatility-factor),
        current-supply: (get-total-available-supply),
        current-demand: (get-current-market-demand),
    }
)

(define-read-only (get-demand-metrics-entry (index uint))
    (map-get? demand-metrics index)
)

(define-map participant-reputation
    principal
    {
        total-trades: uint,
        successful-trades: uint,
        failed-trades: uint,
        reputation-score: uint,
        last-updated: uint,
    }
)

(define-map reputation-thresholds
    (string-ascii 20)
    uint
)

(define-constant ERR-LOW-REPUTATION (err u105))
(define-constant MIN-REPUTATION-SCORE u60)

(define-public (initialize-reputation-thresholds)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (map-set reputation-thresholds "excellent" u90)
        (map-set reputation-thresholds "good" u70)
        (map-set reputation-thresholds "acceptable" u50)
        (map-set reputation-thresholds "poor" u30)
        (ok true)
    )
)

(define-public (update-participant-reputation
        (participant principal)
        (trade-successful bool)
    )
    (let (
            (current-rep (default-to {
                total-trades: u0,
                successful-trades: u0,
                failed-trades: u0,
                reputation-score: u100,
                last-updated: u0,
            }
                (map-get? participant-reputation participant)
            ))
            (new-total (+ (get total-trades current-rep) u1))
            (new-successful (if trade-successful
                (+ (get successful-trades current-rep) u1)
                (get successful-trades current-rep)
            ))
            (new-failed (if (not trade-successful)
                (+ (get failed-trades current-rep) u1)
                (get failed-trades current-rep)
            ))
            (success-rate (if (> new-total u0)
                (/ (* new-successful u100) new-total)
                u100
            ))
        )
        (begin
            (map-set participant-reputation participant {
                total-trades: new-total,
                successful-trades: new-successful,
                failed-trades: new-failed,
                reputation-score: success-rate,
                last-updated: burn-block-height,
            })
            (ok success-rate)
        )
    )
)

(define-public (create-reputation-verified-trade
        (seller principal)
        (amount uint)
    )
    (let (
            (seller-rep (get-participant-reputation-score seller))
            (buyer-rep (get-participant-reputation-score tx-sender))
        )
        (begin
            (asserts! (>= seller-rep MIN-REPUTATION-SCORE) ERR-LOW-REPUTATION)
            (asserts! (>= buyer-rep MIN-REPUTATION-SCORE) ERR-LOW-REPUTATION)
            (create-trade seller amount)
        )
    )
)

(define-public (complete-reputation-trade
        (trade-id uint)
        (seller principal)
    )
    (begin
        (try! (accept-trade trade-id seller))
        (unwrap! (update-participant-reputation seller true) ERR-INVALID-AMOUNT)
        (unwrap! (update-participant-reputation tx-sender true)
            ERR-INVALID-AMOUNT
        )
        (ok true)
    )
)

(define-public (report-failed-trade
        (participant principal)
        (trade-id uint)
    )
    (let ((trade (unwrap! (get-trade-info participant trade-id) ERR-TRADE-NOT-FOUND)))
        (begin
            (asserts!
                (or
                    (is-eq tx-sender (get buyer trade))
                    (is-eq tx-sender participant)
                )
                ERR-UNAUTHORIZED
            )
            (unwrap! (update-participant-reputation participant false)
                ERR-INVALID-AMOUNT
            )
            (ok true)
        )
    )
)

(define-read-only (get-participant-reputation-score (participant principal))
    (let ((rep-data (map-get? participant-reputation participant)))
        (if (is-some rep-data)
            (get reputation-score (unwrap-panic rep-data))
            u100
        )
    )
)

(define-read-only (get-reputation-category (participant principal))
    (let (
            (score (get-participant-reputation-score participant))
            (excellent-threshold (default-to u90 (map-get? reputation-thresholds "excellent")))
            (good-threshold (default-to u70 (map-get? reputation-thresholds "good")))
            (acceptable-threshold (default-to u50 (map-get? reputation-thresholds "acceptable")))
        )
        (if (>= score excellent-threshold)
            "excellent"
            (if (>= score good-threshold)
                "good"
                (if (>= score acceptable-threshold)
                    "acceptable"
                    "poor"
                )
            )
        )
    )
)

(define-read-only (get-reputation-details (participant principal))
    (map-get? participant-reputation participant)
)

(define-read-only (is-reliable-trader (participant principal))
    (>= (get-participant-reputation-score participant) MIN-REPUTATION-SCORE)
)

(define-public (set-minimum-reputation-score (new-score uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (asserts! (and (>= new-score u0) (<= new-score u100)) ERR-INVALID-AMOUNT)
        (ok true)
    )
)

;; =================
;; REC TRADING SYSTEM
;; =================

;; REC Error Constants
(define-constant ERR-REC-NOT-FOUND (err u200))
(define-constant ERR-REC-EXPIRED (err u201))
(define-constant ERR-INVALID-CERTIFICATION (err u202))
(define-constant ERR-REC-ALREADY-SOLD (err u203))
(define-constant ERR-INSUFFICIENT-REC-BALANCE (err u204))
(define-constant ERR-INVALID-ENERGY-SOURCE (err u205))
(define-constant ERR-LISTING-NOT-FOUND (err u206))
(define-constant ERR-CANNOT-BUY-OWN-REC (err u207))

;; REC Data Structures
(define-map rec-registry
    uint
    {
        issuer: principal,
        energy-amount: uint,
        certification-level: (string-ascii 20),
        energy-source: (string-ascii 30),
        issue-date: uint,
        expiry-date: uint,
        is-active: bool,
        carbon-offset: uint,
    }
)

(define-map rec-marketplace
    uint
    {
        rec-id: uint,
        seller: principal,
        price-per-rec: uint,
        quantity: uint,
        listing-date: uint,
        is-available: bool,
    }
)

(define-map rec-portfolios
    principal
    {
        total-recs: uint,
        bronze-recs: uint,
        silver-recs: uint,
        gold-recs: uint,
        platinum-recs: uint,
        total-carbon-offset: uint,
    }
)

(define-map certification-standards
    (string-ascii 20)
    {
        min-efficiency: uint,
        carbon-reduction: uint,
        validity-period: uint,
    }
)

;; REC State Variables
(define-data-var rec-nonce uint u0)
(define-data-var marketplace-nonce uint u0)
(define-data-var default-rec-validity uint u52560)
(define-data-var rec-base-price uint u25)

;; Initialize Certification Standards
(define-public (initialize-rec-standards)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (map-set certification-standards "bronze" {
            min-efficiency: u60,
            carbon-reduction: u25,
            validity-period: u26280,
        })
        (map-set certification-standards "silver" {
            min-efficiency: u75,
            carbon-reduction: u50,
            validity-period: u39420,
        })
        (map-set certification-standards "gold" {
            min-efficiency: u85,
            carbon-reduction: u75,
            validity-period: u52560,
        })
        (map-set certification-standards "platinum" {
            min-efficiency: u95,
            carbon-reduction: u90,
            validity-period: u65700,
        })
        (ok true)
    )
)

;; Issue REC for Energy Production
(define-public (issue-rec
        (energy-amount uint)
        (energy-source (string-ascii 30))
        (efficiency-rating uint)
    )
    (let (
            (new-rec-id (+ (var-get rec-nonce) u1))
            (cert-level (determine-certification-level efficiency-rating))
            (cert-standards (unwrap! (map-get? certification-standards cert-level)
                ERR-INVALID-CERTIFICATION
            ))
            (carbon-offset (/ (* energy-amount (get carbon-reduction cert-standards)) u100))
            (producer-data (unwrap! (map-get? energy-producers tx-sender) ERR-UNAUTHORIZED))
        )
        (begin
            (asserts! (> energy-amount u0) ERR-INVALID-AMOUNT)
            (asserts! (>= efficiency-rating u50) ERR-INVALID-CERTIFICATION)
            (asserts! (validate-energy-source energy-source) ERR-INVALID-ENERGY-SOURCE)
            (var-set rec-nonce new-rec-id)
            (map-set rec-registry new-rec-id {
                issuer: tx-sender,
                energy-amount: energy-amount,
                certification-level: cert-level,
                energy-source: energy-source,
                issue-date: burn-block-height,
                expiry-date: (+ burn-block-height (get validity-period cert-standards)),
                is-active: true,
                carbon-offset: carbon-offset,
            })
            (update-portfolio-on-issue tx-sender cert-level carbon-offset)
            (ok new-rec-id)
        )
    )
)

;; Create REC Marketplace Listing
(define-public (create-rec-listing
        (rec-id uint)
        (price-per-rec uint)
        (quantity uint)
    )
    (let (
            (rec-data (unwrap! (map-get? rec-registry rec-id) ERR-REC-NOT-FOUND))
            (new-listing-id (+ (var-get marketplace-nonce) u1))
        )
        (begin
            (asserts! (is-eq (get issuer rec-data) tx-sender) ERR-UNAUTHORIZED)
            (asserts! (get is-active rec-data) ERR-REC-EXPIRED)
            (asserts! (> quantity u0) ERR-INVALID-AMOUNT)
            (asserts! (> price-per-rec u0) ERR-INVALID-AMOUNT)
            (asserts! (>= (get energy-amount rec-data) quantity) ERR-INSUFFICIENT-REC-BALANCE)
            (var-set marketplace-nonce new-listing-id)
            (map-set rec-marketplace new-listing-id {
                rec-id: rec-id,
                seller: tx-sender,
                price-per-rec: price-per-rec,
                quantity: quantity,
                listing-date: burn-block-height,
                is-available: true,
            })
            (ok new-listing-id)
        )
    )
)

;; Buy RECs from Marketplace
(define-public (buy-recs
        (listing-id uint)
        (quantity uint)
    )
    (let (
            (listing (unwrap! (map-get? rec-marketplace listing-id) ERR-LISTING-NOT-FOUND))
            (rec-data (unwrap! (map-get? rec-registry (get rec-id listing)) ERR-REC-NOT-FOUND))
            (total-cost (* (get price-per-rec listing) quantity))
            (seller (get seller listing))
        )
        (begin
            (asserts! (not (is-eq tx-sender seller)) ERR-CANNOT-BUY-OWN-REC)
            (asserts! (get is-available listing) ERR-REC-ALREADY-SOLD)
            (asserts! (get is-active rec-data) ERR-REC-EXPIRED)
            (asserts! (>= (get quantity listing) quantity) ERR-INSUFFICIENT-REC-BALANCE)
            (try! (stx-transfer? total-cost tx-sender seller))
            (update-marketplace-after-purchase listing-id quantity)
            (update-portfolio-on-purchase tx-sender (get certification-level rec-data) (get carbon-offset rec-data) quantity)
            (ok true)
        )
    )
)

;; Check REC Expiration and Update Status
(define-public (update-rec-status (rec-id uint))
    (let ((rec-data (unwrap! (map-get? rec-registry rec-id) ERR-REC-NOT-FOUND)))
        (begin
            (if (>= burn-block-height (get expiry-date rec-data))
                (begin
                    (map-set rec-registry rec-id
                        (merge rec-data { is-active: false })
                    )
                    (ok "expired")
                )
                (ok "active")
            )
        )
    )
)

;; Transfer RECs Between Users
(define-public (transfer-recs
        (rec-id uint)
        (recipient principal)
        (quantity uint)
    )
    (let (
            (rec-data (unwrap! (map-get? rec-registry rec-id) ERR-REC-NOT-FOUND))
            (sender-portfolio (get-rec-portfolio tx-sender))
        )
        (begin
            (asserts! (is-eq (get issuer rec-data) tx-sender) ERR-UNAUTHORIZED)
            (asserts! (get is-active rec-data) ERR-REC-EXPIRED)
            (asserts! (>= (get energy-amount rec-data) quantity) ERR-INSUFFICIENT-REC-BALANCE)
            (update-portfolio-on-transfer tx-sender recipient (get certification-level rec-data) (get carbon-offset rec-data) quantity)
            (ok true)
        )
    )
)

;; Retire RECs (remove from circulation)
(define-public (retire-recs
        (rec-id uint)
        (quantity uint)
        (retirement-reason (string-ascii 100))
    )
    (let ((rec-data (unwrap! (map-get? rec-registry rec-id) ERR-REC-NOT-FOUND)))
        (begin
            (asserts! (is-eq (get issuer rec-data) tx-sender) ERR-UNAUTHORIZED)
            (asserts! (get is-active rec-data) ERR-REC-EXPIRED)
            (asserts! (>= (get energy-amount rec-data) quantity) ERR-INSUFFICIENT-REC-BALANCE)
            (map-set rec-registry rec-id
                (merge rec-data {
                    energy-amount: (- (get energy-amount rec-data) quantity),
                    is-active: (> (- (get energy-amount rec-data) quantity) u0),
                })
            )
            (ok true)
        )
    )
)

;; Helper Functions
(define-private (determine-certification-level (efficiency uint))
    (if (>= efficiency u95)
        "platinum"
        (if (>= efficiency u85)
            "gold"
            (if (>= efficiency u75)
                "silver"
                "bronze"
            )
        )
    )
)

(define-private (validate-energy-source (source (string-ascii 30)))
    (or
        (is-eq source "solar")
        (or
            (is-eq source "wind")
            (or
                (is-eq source "hydro")
                (or
                    (is-eq source "geothermal")
                    (or
                        (is-eq source "biomass")
                        (is-eq source "nuclear")
                    )
                )
            )
        )
    )
)

(define-private (update-portfolio-on-issue
        (issuer principal)
        (cert-level (string-ascii 20))
        (carbon-offset uint)
    )
    (let (
            (current-portfolio (default-to {
                total-recs: u0,
                bronze-recs: u0,
                silver-recs: u0,
                gold-recs: u0,
                platinum-recs: u0,
                total-carbon-offset: u0,
            }
                (map-get? rec-portfolios issuer)
            ))
        )
        (map-set rec-portfolios issuer {
            total-recs: (+ (get total-recs current-portfolio) u1),
            bronze-recs: (if (is-eq cert-level "bronze")
                (+ (get bronze-recs current-portfolio) u1)
                (get bronze-recs current-portfolio)
            ),
            silver-recs: (if (is-eq cert-level "silver")
                (+ (get silver-recs current-portfolio) u1)
                (get silver-recs current-portfolio)
            ),
            gold-recs: (if (is-eq cert-level "gold")
                (+ (get gold-recs current-portfolio) u1)
                (get gold-recs current-portfolio)
            ),
            platinum-recs: (if (is-eq cert-level "platinum")
                (+ (get platinum-recs current-portfolio) u1)
                (get platinum-recs current-portfolio)
            ),
            total-carbon-offset: (+ (get total-carbon-offset current-portfolio) carbon-offset),
        })
    )
)

(define-private (update-marketplace-after-purchase
        (listing-id uint)
        (purchased-quantity uint)
    )
    (let ((listing (unwrap-panic (map-get? rec-marketplace listing-id))))
        (if (<= purchased-quantity (get quantity listing))
            (map-set rec-marketplace listing-id
                (merge listing {
                    quantity: (- (get quantity listing) purchased-quantity),
                    is-available: (> (- (get quantity listing) purchased-quantity) u0),
                })
            )
            false
        )
    )
)

(define-private (update-portfolio-on-purchase
        (buyer principal)
        (cert-level (string-ascii 20))
        (carbon-offset uint)
        (quantity uint)
    )
    (let (
            (current-portfolio (default-to {
                total-recs: u0,
                bronze-recs: u0,
                silver-recs: u0,
                gold-recs: u0,
                platinum-recs: u0,
                total-carbon-offset: u0,
            }
                (map-get? rec-portfolios buyer)
            ))
        )
        (map-set rec-portfolios buyer {
            total-recs: (+ (get total-recs current-portfolio) quantity),
            bronze-recs: (if (is-eq cert-level "bronze")
                (+ (get bronze-recs current-portfolio) quantity)
                (get bronze-recs current-portfolio)
            ),
            silver-recs: (if (is-eq cert-level "silver")
                (+ (get silver-recs current-portfolio) quantity)
                (get silver-recs current-portfolio)
            ),
            gold-recs: (if (is-eq cert-level "gold")
                (+ (get gold-recs current-portfolio) quantity)
                (get gold-recs current-portfolio)
            ),
            platinum-recs: (if (is-eq cert-level "platinum")
                (+ (get platinum-recs current-portfolio) quantity)
                (get platinum-recs current-portfolio)
            ),
            total-carbon-offset: (+ (get total-carbon-offset current-portfolio) (* carbon-offset quantity)),
        })
    )
)

(define-private (update-portfolio-on-transfer
        (sender principal)
        (recipient principal)
        (cert-level (string-ascii 20))
        (carbon-offset uint)
        (quantity uint)
    )
    (begin
        (update-portfolio-on-purchase recipient cert-level carbon-offset quantity)
        true
    )
)

;; REC Getter Functions
(define-read-only (get-rec-details (rec-id uint))
    (map-get? rec-registry rec-id)
)

(define-read-only (get-rec-listing (listing-id uint))
    (map-get? rec-marketplace listing-id)
)

(define-read-only (get-rec-portfolio (user principal))
    (default-to {
        total-recs: u0,
        bronze-recs: u0,
        silver-recs: u0,
        gold-recs: u0,
        platinum-recs: u0,
        total-carbon-offset: u0,
    }
        (map-get? rec-portfolios user)
    )
)

(define-read-only (get-certification-standard (level (string-ascii 20)))
    (map-get? certification-standards level)
)

(define-read-only (calculate-rec-value
        (cert-level (string-ascii 20))
        (energy-amount uint)
    )
    (let (
            (cert-data (unwrap! (map-get? certification-standards cert-level)
                (err u0)
            ))
            (rec-base-price-val (var-get rec-base-price))
            (efficiency-multiplier (if (is-eq cert-level "platinum")
                u150
                (if (is-eq cert-level "gold")
                    u125
                    (if (is-eq cert-level "silver")
                        u110
                        u100
                    )
                )
            ))
        )
        (ok (/ (* rec-base-price-val energy-amount efficiency-multiplier) u100))
    )
)

(define-read-only (get-active-rec-listings)
    (let ((current-nonce (var-get marketplace-nonce)))
        {
            total-listings: current-nonce,
            marketplace-nonce: current-nonce,
        }
    )
)

(define-read-only (is-rec-valid (rec-id uint))
    (let ((rec-data (map-get? rec-registry rec-id)))
        (if (is-some rec-data)
            (let ((rec (unwrap-panic rec-data)))
                (and
                    (get is-active rec)
                    (< burn-block-height (get expiry-date rec))
                )
            )
            false
        )
    )
)

(define-read-only (get-rec-market-summary)
    {
        total-recs-issued: (var-get rec-nonce),
        total-marketplace-listings: (var-get marketplace-nonce),
        base-rec-price: (var-get rec-base-price),
        default-validity-period: (var-get default-rec-validity),
    }
)

;; Admin Functions for REC System
(define-public (set-rec-base-price (new-price uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (asserts! (> new-price u0) ERR-INVALID-AMOUNT)
        (var-set rec-base-price new-price)
        (ok true)
    )
)

(define-public (set-default-rec-validity (new-validity uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (asserts! (> new-validity u0) ERR-INVALID-AMOUNT)
        (var-set default-rec-validity new-validity)
        (ok true)
    )
)
