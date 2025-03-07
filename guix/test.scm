
(define-module (guix installer)
  #:use-module (guix)
  #:use-module (guix channels)
  #:use-module (guix utils)
  #:use-module (gnu packages version-control)
  #:use-module (gnu packages vim)
  #:use-module (gnu packages curl)
  #:use-module (gnu packages emacs)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages mtools)
  #:use-module (gnu packages tmux)
  #:use-module (gnu packages file-systems)
  #:use-module (gnu packages package-management)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (gnu)
  #:use-module (gnu system)
  #:use-module (gnu system nss)
  #:use-module (gnu system install)
  #:use-module (nongnu packages linux)
  #:use-module (nongnu system linux-initrd)

  #:use-module (antlers records)
  #:use-module (antlers systems transformations oot-modules)

  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix records)

  )

(use-service-modules linux networking desktop sddm xorg ssh)
(use-package-modules linux certs gnome)

(define my-linux linux-6.12)

(define my-zfs
  (linux-module-with-kernel
   my-linux
   (package
    (inherit zfs)
    (arguments
      (cons* #:linux my-linux           ; must be pinned! otherwise base zfs defaults to linux-6.13
             (package-arguments zfs)))))

  )

(define my-linux-with-zfs (kernel-with-oot-modules my-linux `(,#~#$my-zfs:module))
  ;; (package
  ;;  (inherit my-linux)
  ;;  ;; add my-zfs to build outputs
  ;;  )

  )


my-linux-with-zfs
