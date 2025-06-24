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
