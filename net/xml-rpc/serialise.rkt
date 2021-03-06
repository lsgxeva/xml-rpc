#lang racket/base
(require racket/contract
         (only-in net/base64 base64-decode base64-encode-stream)
         racket/date
         racket/match
         "base.rkt")

(provide serialise
         deserialise
         remove-single-spaces
         encode-string
         decode-string)

(define replace-&-and-<
  (let ((amp-re (regexp (regexp-quote "&")))
        (lt-re (regexp (regexp-quote "<"))))
    (lambda (str)
      (regexp-replace* lt-re
                       (regexp-replace* amp-re str "\\&amp;")
                       "\\&lt;"))))

(define replace-entities
  (let ((amp-re (regexp (regexp-quote "&amp;")))
        (lt-re (regexp (regexp-quote "&lt;"))))
    (lambda (str)
      (regexp-replace* amp-re
                       (regexp-replace* lt-re str "<")
                       "\\&"))))

(define identity
  (lambda (x) x))

(define/contract encode-string-guard
  (-> boolean? any)
  (lambda (replace?)
    (if replace?
      replace-&-and-<
      identity)))

(define/contract decode-string-guard
  (-> boolean? any)
  (lambda (replace?)
    (if replace?
      replace-entities
      identity)))

(define encode-string
  (make-parameter replace-&-and-< encode-string-guard))

(define decode-string
  (make-parameter replace-entities decode-string-guard))

;; date->iso8601-string : date -> string
(define (date->iso8601-string date)
  (define (pad number)
    (let ((str (number->string number)))
      (if (< (string-length str) 2)
        (string-append "0" str)
        str)))
  (string-append
   (number->string (date-year date))
   (pad (date-month date))
   (pad (date-day date))
   "T"
   (pad (date-hour date))
   ":"
   (pad (date-minute date))
   ":"
   (pad (date-second date))))

;; serialise : (U integer string boolean double date hash-table list) -> SXML
;;
;; Convert the value to its XML-RPC representation
(define (serialise val)
  (cond
    [(or (eq? +nan.0 val) (eq? +inf.0 val) (eq? -inf.0 val))
     ;; note that +nan.0 = -nan.0 so we don't check this case
     (raise-exn:xml-rpc
      (format "Given ~s to serialise to XML-RPC.  XML-RPC does not allow NaN or infinities; and so this value cannot be serialised" val))]
    [(and (number? val) (inexact? val))
     ;; If I'm correct an inexact number is represented by
     ;; a double, so this should be always in range.
     `(value (double ,(number->string val)))]
    [(integer? val)
     ;; Integers are bound to 4-byte representations by the protocol.
     (if (and (<= val (expt 2 31))
              (>= val (- (expt 2 31))))
       `(value (int ,(number->string val)))
       (raise-exn:xml-rpc
        (format "The Racket number ~s is out of range for an XML-RPC integer" val)))]
    [(string? val)  `(value (string ,val))]
    ;; 20060711 MCJ
    ;; We could encode symbols as strings. However, this breaks
    ;; the semantics of Racket. Should we force users to send
    ;; symbols as strings, or do an automatic conversion?
    ;; Currently, both lists and vectors map to the same XML-RPC datastructure,
    ;; so this is not unprecedented.
    [(symbol? val)  `(value (string ,((encode-string) (symbol->string val))))]
    [(boolean? val) `(value (boolean ,(if val "1" "0")))]
    [(date? val) `(value (dateTime.iso8601
                          ,(date->iso8601-string val)))]
    [(hash? val)
     `(value (struct ,@(hash-map
                        val
                        (lambda (k v)
                          `(member (name ,(symbol->string k))
                                   ,(serialise v))))))]
    [(list? val)
     `(value (array (data ,@(map serialise val))))]
    [(vector? val)
     `(value (array (data ,@(map serialise (vector->list val)))))]
    [(bytes? val)
     `(value (base64 ,(xml-rpc:base64-encode val)))]
    [else
     (raise-exn:xml-rpc
      (format "Cannot convert Racket value ~s to XML-RPC" val))]))

(define (xml-rpc:base64-encode byte)
  (let ((output (open-output-string)))
    (base64-encode-stream
     (open-input-bytes byte)
     output
     #"")
    (get-output-string output)))

;; deserialise-struct : list-of-SXML -> Racket value
(define (deserialise-struct member*)
  (let ([h (make-hash)])
    (for-each
     (lambda (member)
       (match member
         ;; They may have shipped the empty string; this is optionally encoded
         ;; as (value) in the API. Perhaps we should deserialize this differently?
         ;; Either way, this is a quick fix for the problem.
         [(list 'member " " ... (list 'name " " ...  name " " ... ) " " ...  
                (list 'value " " ...)
                " " ...)
          (hash-set! h (string->symbol name) "")]

         ;; This works if we have a value here...
         [(list 'member " " ... (list 'name " " ...  name " " ...) " " ...
                (list 'value " " ...  v " " ... )
                " " ...)
          (hash-set! h (string->symbol name) (deserialise v))]
         [else
          (raise-exn:xml-rpc
           (format "The XML-RPC struct data ~s is badly formed and cannot be converted to Racket" else))]))
     member*)
    h))

(define (deserialize-iso8601 v)
  ;;<value><dateTime.iso8601>20051030T22:29:34</dateTime.iso8601></value>
  (let ([pieces (regexp-match
                 #px"(\\d\\d\\d\\d)(\\d\\d)(\\d\\d)T(\\d\\d):(\\d\\d):(\\d\\d)" v)])
    (if pieces
      (let-values ([(all year month day h m s)
                    (apply values (map string->number pieces))])
        (let* ([given-date (seconds->date (find-seconds s m h day month year))]
               [tzo
                (date-time-zone-offset (seconds->date (current-seconds)))])
          (struct-copy date given-date (time-zone-offset tzo))
          ))
      (raise-exn:xml-rpc
       (format
        "The XML-RPC date ~s badly formatted; cannot be converted to Racket" v)))))

;; deserialise : sxml -> (U float boolean integer string date hash list)
(define (deserialise val)
  (match val
    ;; Our struct deserialiser can dump here with a bare string.
    ;; We need to guard against that and simply return the string.
    [(? string? bare-string) bare-string]
    [(list 'value " " ... type " " ...)
     (cond
       [(list? type)
        (deserialise type)]
       [(string? type)
        ;; This is the default case if not type information
        ;; is given
        type])]
    [(list 'value " " ...) ""]
    ;; Numbers
    [(list 'int " " ... v " " ...)
     (string->number v)]
    [(list 'i4 " " ... v " " ...) (string->number v)]
    [(list 'double " " ... v " " ...) (string->number v)]
    ;; Strings
    [(list 'string " " ...) ""]
    [(list 'string " " ... v " " ...) v]

    ;; Booleans
    [(list 'boolean " " ... v " " ...) (string=? v "1")]
    ;; Date
    [(list 'dateTime.iso8601 " " ... v " " ...)
     (deserialize-iso8601 v)]
    ;; B64
    ;; 20060829 MCJ
    ;; Apparently, the Apache XML-RPC v2 library sends
    ;; an empty Base64 tag if no data is present.
    [(list 'base64 " " ...) #""]
    [(list 'base64 " " ... v " " ...)
     (base64-decode (string->bytes/utf-8 v))]
    ;; Structs
    [(list 'struct member* ...)
     (deserialise-struct (remove-single-spaces member*))]
    ;; Arrays
    [(list 'array " " ... (list 'data value* ...) " " ...)
     (map deserialise (remove-single-spaces value*))]
    [else
     (raise-exn:xml-rpc
      (format "Cannot convert the XML-RPC type ~v to Racket" else))]))

(define (remove-single-spaces l)
  (filter (λ (s) (not (equal? " " s))) l))
