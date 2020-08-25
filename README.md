# ess-view-data
View data support for ESS

## Installation

Clone this repository, or install from MELPA. Add the following to your `.emacs`:

``` elisp
(require 'ess-view-data)
```

## Customization

### ess-view-data-backend-list 

- dplyr (default)
- dplyr+DT
- data.table+magrittr

### ess-view-data-print-backend-list

- print (default)
- kable

### ess-view-data-save-backend-list

- write.csv (default)
- readr::write_csv
- data.table::fwrite
- kable

### ess-view-data-complete-backend-list

- jsonlite

### ess-view-data-read-string

- ess-completing-read (default)
- completing-read
- ido-completing-read
- ivy-completing-read


## Usage

**NOTE**: it will make a copy of the data and then does the following action

[x] ess-view-data-print: the main function to view data
[x] ess-view-data-set-backend: change backend
[x] ess-view-data-toggle-maxprint: toggle limitation of lines per page to print
[x] ess-view-data-filter:
[x] ess-view-data-select / ess-view-data-unselect
[x] ess-view-data-sort
[x] ess-view-data-group / ess-view-data-ungroup
[x] ess-view-data-mutate
[x] ess-view-data-slice
[x] ess-view-data-wide2long / ess-view-data-long2wide
[x] ess-view-data-update
[x] ess-view-data-reset
[x] ess-view-data-unique
[x] ess-view-data-count
[x] ess-view-data-summarise
[x] ess-view-data-overview
[x] ess-view-data-goto-page / -next-page / -preious-page / -first-page / -last-page / -page-number
[x] ess-view-data-save
