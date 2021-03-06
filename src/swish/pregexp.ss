;;; Portable regular expressions for Scheme
;;; Copyright (c) 1999-2005, Dorai Sitaram.
;;; All rights reserved.
;;; http://www.ccs.neu.edu/~dorai
;;; dorai@ccs.neu.edu
;;; Oct 2, 1999

;;; Permission to copy, modify, distribute, and use this work or
;;; a modified copy of this work, for any purpose, is hereby
;;; granted, provided that the copy includes this copyright
;;; notice, and in the case of a modified copy, also includes a
;;; notice of modification.  This work is provided as is, with
;;; no warranty of any kind.

;;; Ported to Chez Scheme by Bob Burger
;;; - added library wrapper
;;; - added re macro for compile-time parsing
;;; - updated replace functions to use a string output port for efficiency
;;; - removed unused sn argument from pregexp-match-positions-aux
;;; - lookbehind matching handles newlines and honors non-zero start
;;; - removed *pregexp-version*
;;; - inlined *pregexp-comment-char*, *pregexp-nul-char-int*,
;;;   *pregexp-return-char*, and *pregexp-tab-char*
;;; - renamed pregexp-reverse! to reverse!
;;; - rewrote pregexp-error as a macro that calls throw
;;; - updated multiple-arity procedures to use case-lambda
;;; - used a process parameter for *pregexp-space-sensitive?*
;;; - used brackets where appropriate

(library (swish pregexp)
  (export
   pregexp
   pregexp-match
   pregexp-match-positions
   pregexp-quote
   pregexp-replace
   pregexp-replace*
   pregexp-split
   re
   )
  (import
   (chezscheme)
   (swish erlang)
   )

  ;; compile static regular expressions at expand time
  (define-syntax re
    (syntax-rules ()
      [(_ e)
       ;; work around out-of-phase identifier
       (let-syntax ([re re-transformer])
         (re e))]))

  (define (re-transformer x)
    (syntax-case x ()
      [(re pat)
       (let ([s (datum pat)])
         (if (string? s)
             #`(quote #,(datum->syntax #'re (pregexp s)))
             #`(pregexp pat)))]))

  (define *pregexp-comment-char* #\;)

  (define pregexp-space-sensitive?
    (make-process-parameter #t (lambda (x) (and x #t))))

  (define-syntax *pregexp-space-sensitive?*
    (identifier-syntax
     [id (pregexp-space-sensitive?)]
     [(set! id val) (pregexp-space-sensitive? val)]))

  (define-syntax pregexp-error
    (syntax-rules ()
      [(_ e1 e2 ...) (throw `#(pregexp-error ,e1 ,e2 ...))]))

  (define (pregexp-read-pattern s i n)
    (if (>= i n)
        (list (list ':or (list ':seq)) i)
        (let loop ([branches '()] [i i])
          (if (or (>= i n)
                  (char=? (string-ref s i) #\)))
              (list (cons ':or (reverse! branches)) i)
              (let ([vv (pregexp-read-branch
                         s
                         (if (char=? (string-ref s i) #\|) (+ i 1) i) n)])
                (loop (cons (car vv) branches) (cadr vv)))))))

  (define (pregexp-read-branch s i n)
    (let loop ([pieces '()] [i i])
      (cond
       [(>= i n) (list (cons ':seq (reverse! pieces)) i)]
       [(let ((c (string-ref s i)))
          (or (char=? c #\|)
              (char=? c #\))))
        (list (cons ':seq (reverse! pieces)) i)]
       [else (let ([vv (pregexp-read-piece s i n)])
               (loop (cons (car vv) pieces) (cadr vv)))])))

  (define (pregexp-read-piece s i n)
    (let ([c (string-ref s i)])
      (case c
        [(#\^) (list ':bos (+ i 1))]
        [(#\$) (list ':eos (+ i 1))]
        [(#\.) (pregexp-wrap-quantifier-if-any
                (list ':any (+ i 1)) s n)]
        [(#\[) (let ([i+1 (+ i 1)])
                 (pregexp-wrap-quantifier-if-any
                  (case (and (< i+1 n) (string-ref s i+1))
                    [(#\^)
                     (let ((vv (pregexp-read-char-list s (+ i 2) n)))
                       (list (list ':neg-char (car vv)) (cadr vv)))]
                    [else (pregexp-read-char-list s i+1 n)])
                  s n))]
        [(#\()
         (pregexp-wrap-quantifier-if-any
          (pregexp-read-subpattern s (+ i 1) n) s n)]
        [(#\\)
         (pregexp-wrap-quantifier-if-any
          (cond
           [(pregexp-read-escaped-number s i n) =>
            (lambda (num-i) (list (list ':backref (car num-i)) (cadr num-i)))]
           [(pregexp-read-escaped-char s i n) =>
            (lambda (char-i) (list (car char-i) (cadr char-i)))]
           [else (pregexp-error 'pregexp-read-piece 'backslash)])
          s n)]
        [else
         (if (or *pregexp-space-sensitive?*
                 (and (not (char-whitespace? c))
                      (not (char=? c *pregexp-comment-char*))))
             (pregexp-wrap-quantifier-if-any
              (list c (+ i 1)) s n)
             (let loop ([i i] [in-comment? #f])
               (if (>= i n) (list ':empty i)
                   (let ([c (string-ref s i)])
                     (cond
                      [in-comment?
                       (loop (+ i 1)
                         (not (char=? c #\newline)))]
                      [(char-whitespace? c)
                       (loop (+ i 1) #f)]
                      [(char=? c *pregexp-comment-char*)
                       (loop (+ i 1) #t)]
                      [else (list ':empty i)])))))])))

  (define (pregexp-read-escaped-number s i n)
    ;; s[i] = \
    (and (< (+ i 1) n) ;; must have at least something following \
         (let ([c (string-ref s (+ i 1))])
           (and (char-numeric? c)
                (let loop ([i (+ i 2)] [r (list c)])
                  (if (>= i n)
                      (list (string->number
                             (list->string (reverse! r))) i)
                      (let ([c (string-ref s i)])
                        (if (char-numeric? c)
                            (loop (+ i 1) (cons c r))
                            (list (string->number
                                   (list->string (reverse! r)))
                              i)))))))))

  (define (pregexp-read-escaped-char s i n)
    ;; s[i] = \
    (and (< (+ i 1) n)
         (let ([c (string-ref s (+ i 1))])
           (case c
             [(#\b) (list ':wbdry (+ i 2))]
             [(#\B) (list ':not-wbdry (+ i 2))]
             [(#\d) (list ':digit (+ i 2))]
             [(#\D) (list '(:neg-char :digit) (+ i 2))]
             [(#\n) (list #\newline (+ i 2))]
             [(#\r) (list #\return (+ i 2))]
             [(#\s) (list ':space (+ i 2))]
             [(#\S) (list '(:neg-char :space) (+ i 2))]
             [(#\t) (list #\tab (+ i 2))]
             [(#\w) (list ':word (+ i 2))]
             [(#\W) (list '(:neg-char :word) (+ i 2))]
             [else (list c (+ i 2))]))))

  (define (pregexp-read-posix-char-class s i n)
    ;; lbrack, colon already read
    (let ([neg? #f])
      (let loop ([i i] [r (list #\:)])
        (if (>= i n)
            (pregexp-error 'pregexp-read-posix-char-class)
            (let ([c (string-ref s i)])
              (cond
               [(char=? c #\^)
                (set! neg? #t)
                (loop (+ i 1) r)]
               [(char-alphabetic? c)
                (loop (+ i 1) (cons c r))]
               [(char=? c #\:)
                (if (or (>= (+ i 1) n)
                        (not (char=? (string-ref s (+ i 1)) #\])))
                    (pregexp-error 'pregexp-read-posix-char-class)
                    (let ([posix-class
                           (string->symbol
                            (list->string (reverse! r)))])
                      (list (if neg? (list ':neg-char posix-class)
                                posix-class)
                        (+ i 2))))]
               [else
                (pregexp-error 'pregexp-read-posix-char-class)]))))))

  (define (pregexp-read-cluster-type s i n)
    ;; s[i-1] = left-paren
    (let ([c (string-ref s i)])
      (case c
        [(#\?)
         (let ([i (+ i 1)])
           (case (string-ref s i)
             ((#\:) (list '() (+ i 1)))
             ((#\=) (list '(:lookahead) (+ i 1)))
             ((#\!) (list '(:neg-lookahead) (+ i 1)))
             ((#\>) (list '(:no-backtrack) (+ i 1)))
             ((#\<)
              (list (case (string-ref s (+ i 1))
                      ((#\=) '(:lookbehind))
                      ((#\!) '(:neg-lookbehind))
                      (else (pregexp-error 'pregexp-read-cluster-type)))
                (+ i 2)))
             (else (let loop ([i i] [r '()] [inv? #f])
                     (let ([c (string-ref s i)])
                       (case c
                         ((#\-) (loop (+ i 1) r #t))
                         ((#\i) (loop (+ i 1)
                                  (cons (if inv? ':case-sensitive
                                            ':case-insensitive) r) #f))
                         ((#\x)
                          (set! *pregexp-space-sensitive?* inv?)
                          (loop (+ i 1) r #f))
                         ((#\:) (list r (+ i 1)))
                         (else (pregexp-error
                                'pregexp-read-cluster-type))))))))]
        [else (list '(:sub) i)])))

  (define (pregexp-read-subpattern s i n)
    (let* ([remember-space-sensitive? *pregexp-space-sensitive?*]
           [ctyp-i (pregexp-read-cluster-type s i n)]
           [ctyp (car ctyp-i)]
           [i (cadr ctyp-i)]
           [vv (pregexp-read-pattern s i n)])
      (set! *pregexp-space-sensitive?* remember-space-sensitive?)
      (let ([vv-re (car vv)]
            [vv-i (cadr vv)])
        (if (and (< vv-i n)
                 (char=? (string-ref s vv-i)
                   #\)))
            (list
             (let loop ([ctyp ctyp] [re vv-re])
               (if (null? ctyp) re
                   (loop (cdr ctyp)
                     (list (car ctyp) re))))
             (+ vv-i 1))
            (pregexp-error 'pregexp-read-subpattern)))))

  (define (pregexp-wrap-quantifier-if-any vv s n)
    (let ([re (car vv)])
      (let loop ([i (cadr vv)])
        (if (>= i n) vv
            (let ([c (string-ref s i)])
              (if (and (char-whitespace? c) (not *pregexp-space-sensitive?*))
                  (loop (+ i 1))
                  (case c
                    [(#\* #\+ #\? #\{)
                     (let* ([new-re (list ':between 'minimal?
                                      'at-least 'at-most re)]
                            [new-vv (list new-re 'next-i)])
                       (case c
                         ((#\*) (set-car! (cddr new-re) 0)
                          (set-car! (cdddr new-re) #f))
                         ((#\+) (set-car! (cddr new-re) 1)
                          (set-car! (cdddr new-re) #f))
                         ((#\?) (set-car! (cddr new-re) 0)
                          (set-car! (cdddr new-re) 1))
                         ((#\{) (let ([pq (pregexp-read-nums s (+ i 1) n)])
                                  (if (not pq)
                                      (pregexp-error
                                       'pregexp-wrap-quantifier-if-any
                                       'left-brace-must-be-followed-by-number))
                                  (set-car! (cddr new-re) (car pq))
                                  (set-car! (cdddr new-re) (cadr pq))
                                  (set! i (caddr pq)))))
                       (let loop ([i (+ i 1)])
                         (if (>= i n)
                             (begin (set-car! (cdr new-re) #f)
                                    (set-car! (cdr new-vv) i))
                             (let ([c (string-ref s i)])
                               (cond
                                [(and (char-whitespace? c)
                                      (not *pregexp-space-sensitive?*))
                                 (loop (+ i 1))]
                                [(char=? c #\?)
                                 (set-car! (cdr new-re) #t)
                                 (set-car! (cdr new-vv) (+ i 1))]
                                [else (set-car! (cdr new-re) #f)
                                  (set-car! (cdr new-vv) i)]))))
                       new-vv)]
                    [else vv])))))))

  (define (pregexp-read-nums s i n)
    ;; s[i-1] = {
    ;; returns (p q k) where s[k] = }
    (let loop ([p '()] [q '()] [k i] [reading 1])
      (if (>= k n) (pregexp-error 'pregexp-read-nums))
      (let ([c (string-ref s k)])
        (cond
         [(char-numeric? c)
          (if (= reading 1)
              (loop (cons c p) q (+ k 1) 1)
              (loop p (cons c q) (+ k 1) 2))]
         [(and (char-whitespace? c) (not *pregexp-space-sensitive?*))
          (loop p q (+ k 1) reading)]
         [(and (char=? c #\,) (= reading 1))
          (loop p q (+ k 1) 2)]
         [(char=? c #\})
          (let ([p (string->number (list->string (reverse! p)))]
                [q (string->number (list->string (reverse! q)))])
            (cond
             [(and (not p) (= reading 1)) (list 0 #f k)]
             [(= reading 1) (list p p k)]
             [else (list p q k)]))]
         [else #f]))))

  (define (pregexp-invert-char-list vv)
    (set-car! (car vv) ':none-of-chars)
    vv)

  (define (pregexp-read-char-list s i n)
    (let loop ([r '()] [i i])
      (if (>= i n)
          (pregexp-error 'pregexp-read-char-list
            'character-class-ended-too-soon)
          (let ([c (string-ref s i)])
            (case c
              [(#\]) (if (null? r)
                         (loop (cons c r) (+ i 1))
                         (list (cons ':one-of-chars (reverse! r))
                           (+ i 1)))]
              [(#\\)
               (let ([char-i (pregexp-read-escaped-char s i n)])
                 (if char-i (loop (cons (car char-i) r) (cadr char-i))
                     (pregexp-error 'pregexp-read-char-list 'backslash)))]
              [(#\-) (if (or (null? r)
                             (let ([i+1 (+ i 1)])
                               (and (< i+1 n)
                                    (char=? (string-ref s i+1) #\]))))
                         (loop (cons c r) (+ i 1))
                         (let ([c-prev (car r)])
                           (if (char? c-prev)
                               (loop (cons (list ':char-range c-prev
                                             (string-ref s (+ i 1))) (cdr r))
                                 (+ i 2))
                               (loop (cons c r) (+ i 1)))))]
              [(#\[) (if (char=? (string-ref s (+ i 1)) #\:)
                         (let ([posix-char-class-i
                                (pregexp-read-posix-char-class s (+ i 2) n)])
                           (loop (cons (car posix-char-class-i) r)
                             (cadr posix-char-class-i)))
                         (loop (cons c r) (+ i 1)))]
              [else (loop (cons c r) (+ i 1))])))))

  (define (pregexp-string-match s1 s i n sk fk)
    (let ([n1 (string-length s1)])
      (if (> n1 n) (fk)
          (let loop ([j 0] [k i])
            (cond
             [(>= j n1) (sk k)]
             [(>= k n) (fk)]
             [(char=? (string-ref s1 j) (string-ref s k))
              (loop (+ j 1) (+ k 1))]
             [else (fk)])))))

  (define (pregexp-char-word? c)
    ;; too restrictive for Scheme but this
    ;; is what \w is in most regexp notations
    (or (char-alphabetic? c)
        (char-numeric? c)
        (char=? c #\_)))

  (define (pregexp-at-word-boundary? s i n)
    (or (= i 0) (>= i n)
        (let ([c/i (string-ref s i)]
              [c/i-1 (string-ref s (- i 1))])
          (let ([c/i/w? (pregexp-check-if-in-char-class?
                         c/i ':word)]
                [c/i-1/w? (pregexp-check-if-in-char-class?
                           c/i-1 ':word)])
            (or (and c/i/w? (not c/i-1/w?))
                (and (not c/i/w?) c/i-1/w?))))))

  (define (pregexp-check-if-in-char-class? c char-class)
    (case char-class
      [(:any) (not (char=? c #\newline))]
      [(:alnum) (or (char-alphabetic? c) (char-numeric? c))]
      [(:alpha) (char-alphabetic? c)]
      [(:ascii) (< (char->integer c) 128)]
      [(:blank) (or (char=? c #\space) (char=? c #\tab))]
      [(:cntrl) (< (char->integer c) 32)]
      [(:digit) (char-numeric? c)]
      [(:graph) (and (>= (char->integer c) 32)
                     (not (char-whitespace? c)))]
      [(:lower) (char-lower-case? c)]
      [(:print) (>= (char->integer c) 32)]
      [(:punct) (and (>= (char->integer c) 32)
                     (not (char-whitespace? c))
                     (not (char-alphabetic? c))
                     (not (char-numeric? c)))]
      [(:space) (char-whitespace? c)]
      [(:upper) (char-upper-case? c)]
      [(:word) (or (char-alphabetic? c)
                   (char-numeric? c)
                   (char=? c #\_))]
      [(:xdigit) (or (char-numeric? c)
                     (char-ci=? c #\a) (char-ci=? c #\b)
                     (char-ci=? c #\c) (char-ci=? c #\d)
                     (char-ci=? c #\e) (char-ci=? c #\f))]
      [else (pregexp-error 'pregexp-check-if-in-char-class?)]))

  (define (pregexp-list-ref s i)
    ;; like list-ref but returns #f if index is out of bounds
    (let loop ([s s] [k 0])
      (cond
       [(null? s) #f]
       [(= k i) (car s)]
       [else (loop (cdr s) (+ k 1))])))

  ;; re is a compiled regexp.  It's a list that can't be
  ;; nil.  pregexp-match-positions-aux returns a 2-elt list whose
  ;; car is the string-index following the matched
  ;; portion and whose cadr contains the submatches.
  ;; The proc returns false if there's no match.

  (define (pregexp-make-backref-list re)
    (let sub ([re re])
      (if (pair? re)
          (let ([car-re (car re)]
                [sub-cdr-re (sub (cdr re))])
            (if (eq? car-re ':sub)
                (cons (cons re #f) sub-cdr-re)
                (append (sub car-re) sub-cdr-re)))
          '())))

  (define (pregexp-match-positions-aux re s start n i)
    (let ([identity (lambda (x) x)]
          [backrefs (pregexp-make-backref-list re)]
          [case-sensitive? #t])
      (let sub ([re re] [i i] [sk identity] [fk (lambda () #f)])
        (cond
         [(eq? re ':bos)
          (if (= i start) (sk i) (fk))]
         [(eq? re ':eos)
          (if (>= i n) (sk i) (fk))]
         [(eq? re ':empty)
          (sk i)]
         [(eq? re ':wbdry)
          (if (pregexp-at-word-boundary? s i n)
              (sk i)
              (fk))]
         [(eq? re ':not-wbdry)
          (if (pregexp-at-word-boundary? s i n)
              (fk)
              (sk i))]
         [(and (char? re) (< i n))
          (if ((if case-sensitive? char=? char-ci=?)
               (string-ref s i) re)
              (sk (+ i 1)) (fk))]
         [(and (not (pair? re)) (< i n))
          (if (pregexp-check-if-in-char-class?
               (string-ref s i) re)
              (sk (+ i 1)) (fk))]
         [(and (pair? re) (eq? (car re) ':char-range) (< i n))
          (let ([c (string-ref s i)])
            (if (let ([c< (if case-sensitive? char<=? char-ci<=?)])
                  (and (c< (cadr re) c)
                       (c< c (caddr re))))
                (sk (+ i 1)) (fk)))]
         [(pair? re)
          (case (car re)
            [(:char-range)
             (if (>= i n) (fk)
                 (pregexp-error 'pregexp-match-positions-aux))]
            [(:one-of-chars)
             (if (>= i n) (fk)
                 (let loop-one-of-chars ([chars (cdr re)])
                   (if (null? chars) (fk)
                       (sub (car chars) i sk
                         (lambda ()
                           (loop-one-of-chars (cdr chars)))))))]
            [(:neg-char)
             (if (>= i n) (fk)
                 (sub (cadr re) i
                   (lambda (i1) (fk))
                   (lambda () (sk (+ i 1)))))]
            [(:seq)
             (let loop-seq ([res (cdr re)] [i i])
               (if (null? res) (sk i)
                   (sub (car res) i
                     (lambda (i1)
                       (loop-seq (cdr res) i1))
                     fk)))]
            [(:or)
             (let loop-or ([res (cdr re)])
               (if (null? res) (fk)
                   (sub (car res) i
                     (lambda (i1)
                       (or (sk i1)
                           (loop-or (cdr res))))
                     (lambda () (loop-or (cdr res))))))]
            [(:backref)
             (let* ([c (pregexp-list-ref backrefs (cadr re))]
                    [backref
                     (cond
                      [c => cdr]
                      [else
                       (pregexp-error 'pregexp-match-positions-aux
                         'non-existent-backref re)
                       #f])])
               (if backref
                   (pregexp-string-match
                    (substring s (car backref) (cdr backref))
                    s i n (lambda (i) (sk i)) fk)
                   (sk i)))]
            [(:sub)
             (sub (cadr re) i
               (lambda (i1)
                 (set-cdr! (assv re backrefs) (cons i i1))
                 (sk i1)) fk)]
            [(:lookahead)
             (let ([found-it?
                    (sub (cadr re) i
                      identity (lambda () #f))])
               (if found-it? (sk i) (fk)))]
            [(:neg-lookahead)
             (let ([found-it?
                    (sub (cadr re) i
                      identity (lambda () #f))])
               (if found-it? (fk) (sk i)))]
            [(:lookbehind)
             (let ([found-it?
                    (fluid-let ([n i])
                      (let loop-lookbehind ([re (cadr re)] [i i])
                        (sub re i (lambda (i) (= i n))
                          (lambda ()
                            (and (> i start)
                                 (loop-lookbehind re (- i 1)))))))])
               (if found-it? (sk i) (fk)))]
            [(:neg-lookbehind)
             (let ([found-it?
                    (fluid-let ([n i])
                      (let loop-lookbehind ([re (cadr re)] [i i])
                        (sub re i (lambda (i) (= i n))
                          (lambda ()
                            (and (> i start)
                                 (loop-lookbehind re (- i 1)))))))])
               (if found-it? (fk) (sk i)))]
            [(:no-backtrack)
             (let ([found-it? (sub (cadr re) i
                                identity (lambda () #f))])
               (if found-it?
                   (sk found-it?)
                   (fk)))]
            [(:case-sensitive :case-insensitive)
             (let ([old case-sensitive?])
               (set! case-sensitive?
                 (eq? (car re) ':case-sensitive))
               (sub (cadr re) i
                 (lambda (i1)
                   (set! case-sensitive? old)
                   (sk i1))
                 (lambda ()
                   (set! case-sensitive? old)
                   (fk))))]
            [(:between)
             (let* ([maximal? (not (cadr re))]
                    [p (caddr re)]
                    [q (cadddr re)]
                    [could-loop-infinitely? (and maximal? (not q))]
                    [re (car (cddddr re))])
               (let loop-p ([k 0] [i i])
                 (if (< k p)
                     (sub re i
                       (lambda (i1)
                         (if (and could-loop-infinitely?
                                  (= i1 i))
                             (pregexp-error
                              'pregexp-match-positions-aux
                              'greedy-quantifier-operand-could-be-empty))
                         (loop-p (+ k 1) i1))
                       fk)
                     (let ([q (and q (- q p))])
                       (let loop-q ([k 0] [i i])
                         (let ([fk (lambda () (sk i))])
                           (if (and q (>= k q)) (fk)
                               (if maximal?
                                   (sub re i
                                     (lambda (i1)
                                       (if (and could-loop-infinitely?
                                                (= i1 i))
                                           (pregexp-error
                                            'pregexp-match-positions-aux
                                            'greedy-quantifier-operand-could-be-empty))
                                       (or (loop-q (+ k 1) i1)
                                           (fk)))
                                     fk)
                                   (or (fk)
                                       (sub re i
                                         (lambda (i1)
                                           (loop-q (+ k 1) i1))
                                         fk))))))))))]
            [else (pregexp-error 'pregexp-match-positions-aux)])]
         [(>= i n) (fk)]
         [else (pregexp-error 'pregexp-match-positions-aux)]))
      (let ([backrefs (map cdr backrefs)])
        (and (car backrefs) backrefs))))

  (define (put-substring p str start end)
    (put-string p str start (- end start)))

  (define (pregexp-replace-aux str ins n backrefs p)
    (let loop ([i 0])
      (when (< i n)
        (let ([c (string-ref ins i)])
          (cond
           [(char=? c #\\)
            (let* ([br-i (pregexp-read-escaped-number ins i n)]
                   [br (if br-i
                           (car br-i)
                           (if (char=? (string-ref ins (+ i 1)) #\&)
                               0
                               #f))]
                   [i (if br-i
                          (cadr br-i)
                          (if br
                              (+ i 2)
                              (+ i 1)))])
              (if (not br)
                  (let ([c2 (string-ref ins i)])
                    (unless (char=? c2 #\$)
                      (put-char p c2))
                    (loop (+ i 1)))
                  (let ([backref (pregexp-list-ref backrefs br)])
                    (when backref
                      (put-substring p str (car backref) (cdr backref)))
                    (loop i))))]
           [else
            (put-char p c)
            (loop (+ i 1))])))))

  (define (pregexp s)
    (set! *pregexp-space-sensitive?* #t) ;; in case it got corrupted
    (list ':sub (car (pregexp-read-pattern s 0 (string-length s)))))

  (define pregexp-match-positions
    (case-lambda
     [(pat str)
      (pregexp-match-positions pat str 0)]
     [(pat str start)
      (pregexp-match-positions pat str start (string-length str))]
     [(pat str start end)
      (let ([pat (cond
                  [(string? pat) (pregexp pat)]
                  [(pair? pat) pat]
                  [else (pregexp-error 'pregexp-match-positions
                          'pattern-must-be-compiled-or-string-regexp
                          pat)])])
        (let loop ([i start])
          (and (<= i end)
               (or (pregexp-match-positions-aux pat str start end i)
                   (loop (+ i 1))))))]))

  (define pregexp-match
    (case-lambda
     [(pat str) (pregexp-match pat str 0)]
     [(pat str start) (pregexp-match pat str start (string-length str))]
     [(pat str start end)
      (let ([ix-prs (pregexp-match-positions pat str start end)])
        (and ix-prs
             (map
              (lambda (ix-pr)
                (and ix-pr
                     (substring str (car ix-pr) (cdr ix-pr))))
              ix-prs)))]))

  (define (pregexp-split pat str)
    ;; split str into substrings, using pat as delimiter
    (let ([n (string-length str)])
      (let loop ([i 0] [r '()] [picked-up-one-undelimited-char? #f])
        (cond
         [(>= i n) (reverse! r)]
         [(pregexp-match-positions pat str i n) =>
          (lambda (y)
            (let ([jk (car y)])
              (let ([j (car jk)] [k (cdr jk)])
                (cond
                 [(= j k)
                  (loop (+ k 1)
                    (cons (substring str i (+ j 1)) r) #t)]
                 [(and (= j i) picked-up-one-undelimited-char?)
                  (loop k r #f)]
                 [else
                  (loop k (cons (substring str i j) r) #f)]))))]
         [else (loop n (cons (substring str i n) r) #f)]))))

  (define (pregexp-replace pat str ins)
    (let* ([n (string-length str)]
           [pp (pregexp-match-positions pat str 0 n)])
      (if (not pp)
          str
          (let ([ins-len (string-length ins)]
                [m-i (caar pp)]
                [m-n (cdar pp)]
                [p (open-output-string)])
            (put-substring p str 0 m-i)
            (pregexp-replace-aux str ins ins-len pp p)
            (put-substring p str m-n n)
            (get-output-string p)))))

  (define (pregexp-replace* pat str ins)
    ;; return str with every occurrence of pat
    ;; replaced by ins
    (let ([pat (if (string? pat) (pregexp pat) pat)]
          [n (string-length str)]
          [ins-len (string-length ins)]
          [p (open-output-string)])
      (let loop ([i 0])
        ;; i = index in str to start replacing from
        ;; r = already calculated prefix of answer
        (if (>= i n)
            (get-output-string p)
            (let ([pp (pregexp-match-positions pat str i n)])
              (cond
               [pp
                (put-substring p str i (caar pp))
                (pregexp-replace-aux str ins ins-len pp p)
                (loop (cdar pp))]
               [(= i 0)
                ;; this implies pat didn't match str at
                ;; all, so let's return original str
                str]
               [else
                ;; all matches already found and
                ;; replaced in r, so let's just
                ;; append the rest of str
                (put-substring p str i n)
                (get-output-string p)]))))))

  (define (pregexp-quote s)
    (let loop ([i (- (string-length s) 1)] [r '()])
      (if (< i 0) (list->string r)
          (loop (- i 1)
            (let ([c (string-ref s i)])
              (if (memv c '(#\\ #\. #\? #\* #\+ #\| #\^ #\$
                            #\[ #\] #\{ #\} #\( #\)))
                  (cons #\\ (cons c r))
                  (cons c r))))))))
