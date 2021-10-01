(require 'wucuo)

(add-to-list 'wucuo-exclude-directories ".github")
(add-to-list 'wucuo-exclude-directories "wucuo")

(setq ispell-personal-dictionary ".github/.aspell.en.pws")

(setq-default wucuo-find-file-regexp "^.*\\.\\(el\\|md\\|org\\)")
