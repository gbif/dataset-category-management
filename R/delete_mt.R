# utilty script to start over for debugging purposes 
# currently doesn't work 
library(gbifmt)
library(yaml)
library(dplyr)

args <- commandArgs(trailingOnly = TRUE)

cats <- yaml.load_file("config.yaml")$categories
cat <- cats[1] # only one exists right now 
config <- yaml.load_file(paste0("category-configs/",cat,".yaml"))

get_mt_datasetkey <- function(datasetKey) {
  url <- paste0("https://api.gbif.org/v1/dataset/", datasetKey, "/machineTag")
  response <- httr::GET(url, httr::config(http_version = 2))
  if (httr::status_code(response) == 200) {
    httr::content(response, "parsed")
  } else {
    stop("Failed to fetch machine tags: ", httr::status_code(response))
  }
}

datasetKeys <- readLines("shell/issue_log.txt") |>
stringr::str_split("\t") |>
purrr::map_chr(1) 

existing <- lapply(datasetKeys, function(x) { 
get_mt_datasetkey(x) |>
lapply(tibble::as_tibble) |>
dplyr::bind_rows() |>
dplyr::filter(namespace == config$machineTag$namespace & value == config$machineTag$value) 
}) |> 
dplyr::bind_rows()


# delete all existing machine tags for this category
purrr::transpose(existing) |> 
purrr::map(~ delete_mt(
    uuid=.x$uuid,
    key=.x$key
))

# check if it worked 
get_mt(
machineTagNamespace=config$machineTag$namespace, 
machineTagValue=config$machineTag$value
)

