;;; Copyright © 2019 Alex Griffin <a@ajgrf.com>
;;; Copyright © 2019 Pierre Neidhardt <mail@ambrevar.xyz>
;;; Copyright © 2019,2024 David Wilson <david@daviwil.com>
;;; Copyright © 2022 Jonathan Brielmaier <jonathan.brielmaier@web.de>
;;; Copyright © 2024 Hilton Chain <hako@ultrarare.space>
;;;
;;; This program is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;; Generate a bootable image (e.g. for USB sticks, etc.) with:
;; $ guix system image -t iso9660 installer.scm
;;
;; for installation, see: https://wiki.systemcrafters.net/guix/nonguix-installation-guide/

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

  #:export (installation-os-nonfree))

(use-service-modules linux networking desktop sddm xorg ssh)
(use-package-modules linux certs gnome)


;; https://substitutes.nonguix.org/signing-key.pub
(define %signing-key
  (plain-file "nonguix.pub" "\
(public-key
 (ecc
  (curve Ed25519)
  (q #C1FD53E5D4CE971933EC50C9F307AE2171A2D3B52C804642A7A35F84F3A4EA98#)))"))

(define %channels
  (cons* (channel
          (name 'nonguix)
          (url "https://gitlab.com/nonguix/nonguix")
          ;; Enable signature verification:
          (introduction
           (make-channel-introduction
            "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
            (openpgp-fingerprint
             "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5"))))
         %default-channels))

;;; ======================================================= ;;;
;;;                       zfs additions                     ;;;
;;; ------------------------------------------------------- ;;;
;;; References:
;;; - https://github.com/openzfs/zfs/discussions/11453
;;; - https://www.illucid.net/static/unpublished/erasing-darlings-on-guix
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

(define zfs-shepherd-services
  (let ((zpool            (file-append my-zfs "/sbin/zpool"))
        (zfs              (file-append my-zfs "/sbin/zfs"))
        (scheme-modules   `((srfi srfi-1)
                            (srfi srfi-34)
                            (srfi srfi-35)
                            (rnrs io ports)
                            ,@%default-modules)))
  (define zfs-scan
    (shepherd-service
      (provision '(zfs-scan))
      (documentation "Scans for ZFS pools.")
      (requirement '(kernel-module-loader udev))
      (modules scheme-modules)
      (start #~(lambda _
                 (invoke/quiet #$zpool "import" "-a" "-N")))
      (stop #~(const #f))))

  (define zfs-automount
    (shepherd-service
      (provision '(zfs-automount))
      (documentation "Automounts ZFS data sets.")
      (requirement '(zfs-scan))
      (modules scheme-modules)
      (start #~(lambda _
                 (with-output-to-port
                   (current-error-port)
                   (lambda ()
                     (invoke #$zfs "mount" "-a" "-l")))))
      (stop #~(lambda _
                (chdir "/")
                (invoke/quiet #$zfs "unmount" "-a" "-f")
                #f))))
  (list
   zfs-scan
   zfs-automount)))


;;; ------------------------------------------------------- ;;;
;;; ------------------------------------------------------- ;;;
;;; ------------------------------------------------------- ;;;
;; This is our first monkey-patch.
(set! (@ (gnu system file-systems) %pseudo-file-system-types)
  (cons "zfs" %pseudo-file-system-types))

;; (define %initrd/pre-mount
;;   (with-imported-modules (source-module-closure
;;                           '((guix build syscalls)
;;                             (guix build utils)))
;;     #~(begin
;;         (use-modules (gnu build file-systems)
;;                      (gnu build linux-boot)
;;                      ((guix build syscalls)
;;                       #:hide (file-system-type))
;;                      (guix build utils))

;;         ;; XXX: Major Hack! Enables mounting ZFS datasets via legacy mountpoints.
;;         (let ((orig (@ (gnu build file-systems) canonicalize-device-spec)))
;;           (set! (@ (gnu build file-systems) canonicalize-device-spec)
;;             (lambda (spec)
;;               (let ((device (if (file-system-label? spec)
;;                                 (file-system-label->string spec)
;;                                 spec)))
;;                 (if (and (string? device)
;;                          (char-set-contains? char-set:letter (string-ref device 0))
;;                          (#$%initrd/import-device-zpool device))
;;                     device
;;                     (orig spec))))))

;;         ;; In my actual config this is where I run plymouth and decrypt keyfiles
;;         ;; (but call `load-key' in a per-dataset loop below).
;;         )))

;; (define %initrd/import-device-zpool
;;   #~(lambda (device)
;;       (let ((zpool (substring device 0 (or (string-index device #\/) 0)))
;;             (present? (lambda (device)
;;                         (and (not (zero? (string-length device)))
;;                              (zero? (system* #$(file-append zfs "/sbin/zfs")
;;                                              "list" device))))))
;;         (unless (or (zero? (string-length zpool))
;;                     (present? device))
;;           (invoke #$(file-append zfs "/sbin/zpool") "import" zpool)

;;           ;; Here's where the rollback happens.
;;           ;;
;;           ;; In my actual config I have an ugly loop that handles multiple
;;           ;; zpools and decryption via load-key, hence the more dynamic parsing
;;           ;; above.
;;           ;;
;;           ;; We're just gonna do this for illustrative purposes:
;;           (when (equal? zpool "zpool")
;;             (system* #$(file-append zfs "/sbin/zfs")
;;                      "rollback" "zpool/local/root@blank"))))))

;; (define (%initrd file-systems . kwargs)
;;   (apply raw-initrd
;;     (cons file-systems
;;           (substitute-keyword-arguments kwargs
;;             ((#:linux linux)
;;              #;OMITTED)
;;             ((#:pre-mount pre-mount #t)
;;              #~(begin #$%initrd/pre-mount
;;                       #$pre-mount))))))
;;; ======================================================= ;;;

(define installation-os-nonfree
  (operating-system
    (inherit installation-os)
    (kernel my-linux-with-zfs)
    ;; Add the 'net.ifnames' argument to prevent network interfaces
    ;; from having really long names.  This can cause an issue with
    ;; wpa_supplicant when you try to connect to a wifi network.
    ;;
    ;; For broadcom, blacklist conflicting kernel modules.
    (kernel-arguments '("modprobe.blacklist=b43,b43legacy,ssb,bcm43xx,brcm80211,brcmfmac,brcmsmac,bcma,radeon" "net.ifnames=0"))
    (kernel-loadable-modules (list broadcom-sta (list my-zfs "module")))
    (firmware (cons* iwlwifi-firmware broadcom-bt-firmware linux-firmware %base-firmware))

    ;;; must be included for legacy mounts
    ;; (initrd %initrd)
    ;; The rest of the neccessary ZFS bits and bobs *are* included.
    (initrd microcode-initrd)
    (initrd-modules (cons "zfs" %base-initrd-modules))

    (services
     (cons*
      ;; Include the channel file so that it can be used during installation
      (simple-service
       'channel-file
       etc-service-type
       (list `("channels.scm" ,(local-file "channels.scm"))))

      (service gnome-desktop-service-type)
      ;; To configure OpenSSH, pass an 'openssh-configuration'
      ;; record as a second argument to 'service' below.


      ;; (set-xorg-configuration (xorg-configuration (keyboard-layout (keyboard-layout "us"))))

      (simple-service 'zfs-udev-rules
                      udev-service-type
                      `(,my-zfs))
      (simple-service 'zfs-mod-loader
                      kernel-module-loader-service-type
                      '("zfs")) ;;  might need linux-loadable-module-service-type
      (simple-service 'zfs-shepherd-services
                      shepherd-root-service-type
                      zfs-shepherd-services)
      (simple-service 'zfs-sheperd-services-user-processes
                      user-processes-service-type
                      '(zfs-automount))

      (modify-services
       (operating-system-user-services installation-os)
       (guix-service-type
        config => (guix-configuration
                   (inherit config)
                   (guix (guix-for-channels %channels))
                   (authorized-keys
                    (cons* %signing-key
                           %default-authorized-guix-keys))
                   (substitute-urls
                    `(,@%default-substitute-urls
                      "https://substitutes.nonguix.org"))
                   (channels %channels)))
       ;; (openssh-service-type
       ;;  config =>
       ;;  (service openssh-service-type
       ;;           (openssh-configuration
       ;;            (inherit config)
       ;;            ;; (openssh openssh-sans-x)
       ;;            (permit-root-login #t))))
       )))

    ;; Add some extra packages useful for the installation process
    (packages
     (append (list git curl stow vim emacs-no-x-toolkit tmux my-zfs)
             (operating-system-packages installation-os)))))

installation-os-nonfree
