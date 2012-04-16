;; This is written in Outlet: https://github.com/jlongster/outlet

;; util

(define-macro (case c . variants)
  `(cond
    ,@(map (lambda (exp)
             (if (== (car exp) 'else)
                 exp
                 `((list-find ',(car exp) ,c)
                   ,@(cdr exp))))
           variants)))


(define (list-slice lst start . end)
  (let ((end (if (null? end) (length lst) (car end))))
    (let loop ((lst lst)
               (i 0)
               (acc '()))
      (if (null? lst)
          (reverse acc)
          (loop
           (cdr lst)
           (+ i 1)
           (if (and (>= i start) (< i end))
               (cons (car lst) acc)
               acc))))))

(define (list-pop lst v)
  (reverse
   (fold (lambda (el acc)
           (if (== v el)
               acc
               (cons el acc)))
         '()
         lst)))

(define (atom? exp)
  (or (symbol? exp)
      (literal? exp)))

(define (scan exp eq)
  (and (list? exp)
       (fold (lambda (el acc)
               (if (eq el)
                   (cons el acc)
                   (let ((res (scan el eq)))
                     (if res
                         (list-append res acc)
                         acc))))
             '()
             exp)))

(define (walk exp f)
  (cond
   ((symbol? exp) (or (f exp) exp))
   ((list? exp) (map (lambda (e)
                       (let ((ne (f e)))
                         (if ne ne (walk e f))))
                     exp))
   (else exp)))

;; macros

(define (expand exp)
  (cond
   ((or (atom? exp)
        (vector? exp)
        (dict? exp)) exp)
   ((macro? (car exp))
    (expand ((macro-function (car exp)) exp)))
   ((eq? (car exp) 'quote) exp)
   ((eq? (car exp) 'lambda)
    `(lambda ,(cadr exp)
       ,@(map expand (cddr exp))))
   ((eq? (car exp) 'define)
    `(define ,(cadr exp)
       ,@(map expand (cddr exp))))
   (else (map expand exp))))

(define %macros {})

(define (macro-function name)
  (dict-ref %macros name))

(define (install-macro name f)
  (dict-put! %macros name f))

(define (macro? name)
  (and (dict-ref %macros name) #t))

(install-macro 'define-macro
               (lambda (form e)
                 (let ((sig (cadr form)))
                   (let ((name (car sig))
                         (pattern (cdr sig))
                         (body (cddr form)))
                     ;; install it during expand-time
                     (install-macro name (make-macro pattern body))
                     #t))))

(define (make-macro pattern body)
  (let ((x (gensym))
        (e (gensym)))
    (eval
     `(lambda (,x)
        (let ,(destructure pattern `(cdr ,x) '())
          ,@body)))))

(define (destructure pattern access bindings)
  (cond
   ((null? pattern) bindings)
   ((eq? (car pattern) '.) (cons (list (cadr pattern) access)
                                bindings))
   (else
    (cons (list (car pattern) `(car ,access))
          (destructure (cdr pattern) `(cdr ,access)
                       bindings)))))

;; environments and frames

(define (extend-environment env vars)
  (cons (make-frame vars) env))

(define (empty-dict vals def)
  (zip vals (map (lambda (v) def) vals)))

;; a frame is a two-element vector, a dict representing variables and
;; associated registers and a dict of function names and objects
(define (make-frame vars)
  [(empty-dict vars 'not-allocated)
   (empty-dict '() 'not-created)])

(define (frame-vars frame)
  (vector-ref frame 0))

(define (set-frame-vars! frame vars)
  (vector-put! frame 0 vars))

(define (frame-funcs frame)
  (vector-ref frame 1))

(define (set-frame-funcs! frame funcs)
  (vector-put! frame 1 funcs))

(define top-frame car)

(define (add-to-frame frame vars)
  (let ((v* (frame-vars frame))
        (vf* (frame-funcs frame)))
    (for-each (lambda (var)
                (if (or (dict-ref v* var)
                        (dict-ref vf* var))
                    (throw (str "can't redefine variable: " var))))
              vars)
    (set-frame-vars!
     frame
     (dict-merge v* (empty-dict vars 'not-allocated)))))

(define (add-func-to-frame frame name)
  (let ((v* (frame-vars frame))
        (vf* (frame-funcs frame)))
    (if (or (dict-ref v* name)
            (dict-ref vf* name))
        (throw (str "can't redefine variable: " name)))
    (dict-put! vf* name 'not-created)))

(define (lookup-variable env var)
  (if (list? env)
      (let ((frame (car env))
            (v (dict-ref (frame-vars frame) var)))
        (if v var (lookup-variable (cdr env) var)))
      #f))

(define (lookup-variable-reg env var)
  (if (list? env)
      (let ((frame (car env))
            (v (dict-ref (frame-vars frame) var)))
        (if v v (lookup-variable-reg (cdr env) var)))
      #f))

(define (%allocate-registers env vars free-regs)
  ;; note that we don't verify that all vars exist, that's someone
  ;; else's job
  (if (and (list? env)
           (not (null? vars)))
      (let ((frame (car env))
            (v* (frame-vars frame)))
        (%allocate-registers
         (cdr env)
         (fold (lambda (v acc)
                 (if (== (dict-ref v* v) 'not-allocated)
                     (begin
                       ;; this is hacky, need to check the free regs
                       ;; and pop one off
                       (if (null? free-regs)
                           (throw "ran out of registers, too many variables"))
                       (dict-put! v* v (car free-regs))
                       (set! free-regs (cdr free-regs))
                       acc)
                     (cons v acc)))
               '()
               vars)
         free-regs))))

(define (allocate-registers env vars)
  (let loop ((vars vars)
             (unallocated '())
             (free-regs all-regs))
    (if (null? vars)
        (%allocate-registers env unallocated free-regs)
        (let ((reg (lookup-variable-reg env (car vars))))
          (if (not reg)
              (throw "can't allocate reg for non-existant variable: "
                     v "\nwhat the heck man? why'd you give me that?"))
          (if (== reg 'not-allocated)
              (loop (cdr vars)
                    (cons (car vars) unallocated)
                    free-regs)
              (loop (cdr vars)
                    unallocated
                    (list-pop free-regs reg)))))))

(define (lookup-function env name)
  (if (list? env)
      (let ((frame (car env))
            (def (dict-ref (frame-funcs frame) name)))
        (if def name (lookup-function (cdr env) name)))
      #f))

(define (lookup-function-def env name)
  (if (list? env)
      (let ((frame (car env))
            (def (dict-ref (frame-funcs frame) name)))
        (if def def (lookup-function-def (cdr env) name)))
      #f))

(define (save-function-def! env name def)
  (let ((frame (car env))
        (vf* (frame-funcs frame))
        (vf-def (dict-ref vf* name)))
    (if vf-def
        (begin
          (if (not (== vf-def 'not-created))
              (throw
               (str "can't set function environment, already set: " name)))
          (dict-put! vf* name def))
        (throw "can't set function environment of non-local functio"))))

;; deref

(define (strip-deref var)
  (if (vector? var)
      (vector-ref var 0)
      var))

(define dereference? vector?)

;; J is used to hold the return value
(define all-regs '(A B C X Y Z I))
(define r-init-template (list (make-frame '())))

(define-macro (define-prim func . native?)
  (let ((name (car func))
        (args (cdr func))
        (native? (if (null? native?) #f (car native?))))
    `(let ((env (extend-environment r-init-template
                                    ',args)))
       (add-func-to-frame (top-frame r-init-template) ',name)
       (allocate-registers env ',args)
       
       (save-function-def!
        r-init-template
        ',name
        (make-function-def ',name
                           ',args
                           env
                           '()
                           ,native?)))))

(define-macro (define-native func)
  `(define-prim ,func #t))

(define (r-init-make)
  ;; Copy r-init-template and make a fresh environment
  (let ((frame-template (top-frame r-init-template))
        (frame (make-frame (keys (frame-vars frame-template)))))
    (set-frame-funcs! frame
                      (dict-map (lambda (x) x)
                                (frame-funcs frame-template)))
    (list frame)))

(define r-init #f)

(define (r-init-initialize!)
  (set! r-init (r-init-make)))

;; intermediate representation

(define register? symbol?)
(define label? symbol?)

(define (value? e)
  (or (number? e)
      (register? e)
      (label? e)))

(define (call? e)
  (and (list? e)
       (== (car e) 'CALL)))

(define (make-function-def name args env body . native?)
  (let ((native? (if (null? native?) #f (car native?))))
    `(FUNCTION ,name ,args ,env ,body ,native?)))

(define (function-def? e)
  (and (list? e)
       (== (car e) 'FUNCTION)))

(define function-name cadr)
(define function-args caddr)
(define (function-env f)
  (car (cdddr f)))
(define (function-body f)
  (cadr (cdddr f)))
(define (function-native? f)
  (caddr (cdddr f)))

(define (make-application env name args)
  `(CALL ,env ,name ,args))

(define (application? e)
  (and (list? e)
       (== (car e) 'CALL)))

(define application-env cadr)
(define application-name caddr)
(define (application-args e)
  (car (cdddr e)))

(define (make-set name env v)
  `(SET ,env ,name ,v))

(define (set? e)
  (and (list? e)
       (== (car e) 'SET)))

(define set-name caddr)
(define set-env cadr)
(define (set-value s)
  (car (cdddr s)))

(define (variable-ref? e)
  (and (list? e)
       (== (car e) 'VARIABLE-REF)))

(define (make-const v)
  `(CONST ,v))

(define (const? v)
  (and (list? v)
       (== (car v) 'CONST)))

(define const-value cadr)

(define (make-deref v)
  `(DEREF ,v))

(define (deref? v)
  (and (list? v)
       (== (car v) 'DEREF)))

(define deref-value cadr)

;; compiler

(define (compile-variable v env)
  (let ((var (lookup-variable env v)))
    (if var `(VARIABLE-REF ,v)
        (let ((f (lookup-function env v)))
          (if f `(FUNCTION-REF ,f)
              (throw (str "undefined variable: " v))))
        (throw (str "undefined variable: ") v))))

(define (compile-deref exp env)
  (let ((v (vector-ref exp 0)))
    (if (not (or (number? v) (symbol? v)))
        (throw (str "can't deref expression: " v)))
    (make-deref (compile* v env))))

(define (compile-quoted exp)
  (make-const exp))

(define (compile-definition e e* env)
  (cond
   ((list? e)
    (let ((name (car e)))
      (add-func-to-frame (top-frame env) name)
      (let ((fenv (extend-environment env (cdr e))))
        (let ((def (make-function-def
                    name
                    (cdr e)
                    fenv
                    (compile-sequence e* fenv))))
          (save-function-def! env name def)))))
   ((symbol? e)
    (add-to-frame (top-frame env) (list e))
    (compile-assignment e (car e*) env))
   (else
    (throw (str "invalid define: " e)))))

(define (compile-assignment var exp env)
  (let ((res (compile* exp env))
        (v (lookup-variable env var)))
    (if (not v)
        (throw (str "undefined variable: " var)))
    (make-set v env res)))

(define (compile-sequence e* env)
  (if (list? e*)
      (if (list? (cdr e*))
          (cons (compile* (car e*) env)
                (compile-sequence (cdr e*) env))
          (let ((e (compile* (car e*) env)))
            (if (function-def? e)
                (list e)
                (list `(RETURN ,e)))))
      '()))

(define (compile-application v a* env)
  (let ((frame (top-frame env))
        (vars (frame-vars frame)))
    (if (not (or (register? v)
                 (label? v)))
        (throw (str "cannot apply to non-function type: " v)))
    (let ((f (or (lookup-variable env v)
                 (lookup-function env v)))
          (args (map
                 (lambda (a)
                   (if (and (list? a)
                            (== (car a) 'set!))
                       (throw (str "bad function value: " a)))
                   (compile* a env))
                 a*)))
      (if (not f)
          (throw (str "undefined variable: " v)))
      (make-application env f args))))

(define (compile* exp cenv)
  (cond
   ((atom? exp) (if (symbol? exp)
                    (compile-variable exp cenv)
                    (compile-quoted exp)))
   ((dereference? exp) (compile-deref exp cenv))
   (else
    (case (car exp)
      ((define) (compile-definition (cadr exp) (cddr exp) cenv))
      ((set!) (compile-assignment (cadr exp) (caddr exp) cenv))
      ((if) (compile-conditional exp cenv))
      ((begin) (compile-sequence (cdr exp) cenv))
      (else (compile-application (car exp) (cdr exp) cenv))))))

;; hoist all functions within f
(define (hoist f)
  (define (reconstruct func e*)
    (make-function-def
     (function-name func)
     (function-args func)
     (function-env func)
     (reverse e*)))

  ;; walk through the function body recursively and accumulate 2
  ;; lists, one with expressions and the other with the functions.
  (define sliced
    (fold (lambda (el acc)
            (if (function-def? el)
                (let ((hoisted (hoist el)))
                  (list (car acc)
                        (list-append
                         hoisted
                         (cadr acc))))
                (list (cons el (car acc))
                      (cadr acc))))
          (list '() '())
          (function-body f)))

  ;; Returns a list of functions, reconstructing the original
  ;; function with all functions removed
  (list-append
   (cadr sliced)
   (list (reconstruct f (car sliced)))))

(define (allocate funcs)
  ;; allocate registers for each function
  (map
   (lambda (f)
     (let ((refs (map (lambda (v)
                        (if (variable-ref? v)
                            (cadr v)
                            (set-name v)))
                      (scan (function-body f)
                            (lambda (e) (or (== (car e) 'VARIABLE-REF)
                                       (== (car e) 'SET)))))))
       (allocate-registers (function-env f) refs)))
   funcs)
  funcs)

(define (linearize-deref exp target)
  (let ((x (deref-value exp))
        (v (if (const? x)
               (const-value x)
               x)))
    (if target
        `((SET ,target [,v]))
        [v])))

(define (linearize-reference exp target)
  (if target
      `((SET ,target ,exp))
      '()))

(define (linearize-return exp)
  (linearize (cadr exp) 'J))

(define (replace-variable-refs exp env)
  (walk exp
        (lambda (e)
          (if (== (car e) 'VARIABLE-REF)
              (let ((v (cadr e))
                    (r (lookup-variable-reg env v)))
                (if (not r)
                    (throw "error, register not assigned"))
                r)
              #f))))

(define (linearize-function exp)
  ;; Scan the body for variable references and allocate registers
  (let ((env (function-env exp)))
    `(,(function-name exp)
      ,@(linearize (function-body (replace-variable-refs exp env)))
      (SET PC POP))))

(define (linearize-assignment exp)
  (let ((var (set-name exp))
        (reg (lookup-variable-reg (set-env exp) var))
        (v (set-value exp)))
    (linearize v reg)))

(define (linearize-constant exp target)
  (if target
      `((SET ,target ,(const-value exp)))
      '()))

(define (linearize-arg exp reg used-regs)
  ;; if it's an application, we need to save the regsiters from all
  ;; previous argument values because all crazy things might happen in
  ;; the calling function
  (if (application? exp)
      (list-append
       (map (lambda (r)
              `(SET PUSH ,r))
            used-regs)
       (linearize exp reg)
       (map (lambda (r)
              `(SET ,r POP))
            (reverse used-regs)))
      (linearize exp reg)))

(define (linearize-arguments arg-values arg-regs)  
  (let loop ((a* (keys arg-values))
             (used-regs '())
             (acc '()))
    (if (null? a*)
        acc
        (let ((var (car a*))
              (reg (dict-ref arg-regs var))
              (exp (dict-ref arg-values var)))
          (if (not reg)
              (throw (str "while linearizing application, "
                          "undefined variable: " var)))
          (loop (cdr a*)
                (cons reg used-regs)
                (if (== reg 'not-allocated)
                    acc
                    (list-append
                     acc
                     (linearize-arg exp reg used-regs))))))))

(define (optimized-native-application? exp)
  (let ((env (application-env exp))
        (def (lookup-function-def env (application-name exp))))
    (and
     (function-native? def)
     (fold (lambda (arg acc)
             (and acc (or (const? arg)
                          (symbol? arg)
                          (deref? arg))))
           #t
           (application-args exp)))))

(define (linearize-native-application exp)
  (let ((env (application-env exp))
        (def (lookup-function-def env (application-name exp)))
        (fenv (function-env def))
        (arg-regs (frame-vars (top-frame fenv)))
        (args (application-args exp)))
    (list
     `(,(application-name exp)
       ,@(map (lambda (a)
                (cond
                 ((const? a) (const-value a))
                 ((symbol? a) a)
                 ((deref? a) (linearize-deref a))
                 (else
                  (throw (str "error: can't apply to native function: " a)))))
              (application-args exp))))))

(define (linearize-application exp target)
  (let ((env (application-env exp))
        (def (lookup-function-def env (application-name exp)))
        (fenv (function-env def))
        (regs (fold (lambda (el acc)
                      (if (not (== el 'not-allocated))
                          (cons el acc)
                          acc))
                    '()
                    (vals (frame-vars (top-frame env)))))
        (arg-regs (frame-vars (top-frame fenv)))
        (args (zip (function-args def)
                   (application-args exp))))

    (if (not (== (length (keys args))
                 (length (keys arg-regs))))
        (let ((argv (list->vector (map str args))))
          (throw (str "wrong number of arguments: ("
                      (application-name exp)
                      " "
                      (argv.join " ")
                      ")"))))
    
    (list-append
     (fold (lambda (r acc)
             (if (not (== r target))
                 (cons `(SET PUSH ,r)
                       acc)
                 acc))
           '()
           regs)
     (linearize-arguments args arg-regs)
     (if (function-native? def)
         `((,(application-name exp) ,@(map (lambda (a)
                                             (dict-ref arg-regs a))
                                           (function-args def))))
         (cons `(JSR ,(application-name exp))
               (if (and target (not (== target 'J)))
                   (list `(SET ,target J))
                   '())))
     (fold (lambda (r acc)
             (if (not (== r target))
                 (cons `(SET ,r POP)
                       acc)
                 acc))
           '()
           (reverse regs)))))

(define (linearize exp . target)
  (let ((target (if (null? target) #f (car target))))
    (if (list? exp)
        (case (car exp)
          ((FUNCTION) (linearize-function exp))
          ((RETURN) (linearize-return exp))
          ((CALL) (if (optimized-native-application? exp)
                      (linearize-native-application exp)
                      (linearize-application exp target)))
          ((SET) (linearize-assignment exp))
          ((CONST) (linearize-constant exp target))
          ((DEREF) (linearize-deref exp target))
          (else
           (let loop ((lst exp)
                      (acc '()))
             (if (null? lst)
                 acc
                 (if (null? (cdr lst))
                     (list-append acc
                                  (linearize (car lst) target))
                     (loop (cdr lst)
                           (list-append acc
                                        (linearize (car lst)))))))))
        (if target
            (linearize-reference exp target)
            (throw (str "cannot linearize expression: " exp))))))

(define (compile exp)
  (r-init-initialize!)

  (let ((exp (compile* exp r-init)))
    (cond
     ((atom? exp) exp)
     ((function-def? exp) (allocate (hoist exp)))
     (else
      (reverse
       (fold (lambda (el acc)
               (if (function-def? el)
                   (list-append (allocate (hoist el)) acc)
                   (cons el acc)))
             '()
             exp))))))

(define (output . e*)
  ;; wow, this is bad code
  (define (str* . vals)
    (apply
     str
     (map (lambda (v)
            (cond
             ((number? v)
              (str "0x" (v.toString 16)))
             ((vector? v)
              (str "[" (apply str* (vector->list v)) "]"))
             (else v)))
          vals)))
  
  (for-each (lambda (e)
              (cond
               ((list? e)
                (let ((ln (length e)))
                  (cond
                   ((== ln 2) (println (str* (car e) " " (cadr e))))
                   ((== ln 3) (println (str* (car e) " "
                                             (cadr e) ", "
                                             (caddr e))))
                   (else (throw (str "invalid expression: " e))))))
               ((symbol? e) (println (str ":" e)))
               (else
                (throw (str "invalid expression: " e)))))
            (apply list-append e*)))

;; strip the env objects out of our structure so that we can inspect
;; it easier (envs contain tons of circular references). only works on
;; non-linearized forms
(define (strip-envs exp)
  (if (list? exp)
      (case (car exp)
        ((FUNCTION) `(FUNCTION ,(function-name exp)
                               ,(function-args exp)
                               ,(strip-envs (function-body exp))))
        ((CALL) `(CALL ,(application-name exp) ,(application-args exp)))
        ((SET) `(SET ,(set-name exp) ,(strip-envs (set-value exp))))
        (else (map strip-envs exp)))
      exp))

;; print a non-linearized form without its envs
(define (pp-w/o-envs exp)
  (pp (strip-envs exp)))

(define-prim (+ x y))
(define-prim (- x y))
(define-prim (/ x y))
(define-prim (* x y))
(define-prim (print pos text))
(define-prim (deref x))

(define-native (ADD x y))
(define-native (SET x y))
(define-native (BOR x y))

(define std-lib '())

(output
 '((JSR __main))
 std-lib
 (linearize
  (compile
   (expand
    '(begin
       (define (__main)
         (define color 0xf000)
         (define bg-color 0)

         (define-macro (print pos text)
           (let ((color 0xf000)
                 (bg-color 0))
             (if (and (number? pos)
                      (number? text))
                 `(SET [,(+ 0x8000 pos)]
                       ,(bitwise-or
                         text
                         (bitwise-or color bg-color)))
                 `(print* ,pos ,text))))
         
         (define (print* pos text)
           (ADD pos 0x8000)
           (BOR text color)
           (BOR text bg-color)
           (SET [pos] text))
         
         (print 0 0x35)
         (print 1 0x20)
         (print 2 0x36)
         (print 3 0x20)
         (print 4 0x37)))))))
