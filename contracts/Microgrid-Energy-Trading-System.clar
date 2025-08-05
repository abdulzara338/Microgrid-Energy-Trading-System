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
