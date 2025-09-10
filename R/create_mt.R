
library(gbifmt)
suppressPackageStartupMessages(library(yaml))
suppressPackageStartupMessages(library(dplyr))

args <- commandArgs(trailingOnly = TRUE)

cats <- yaml.load_file("config.yaml")$categories
cat <- cats[1] # only one exists right now 
config <- yaml.load_file(paste0("category-configs/",cat,".yaml"))

datasetKey <- args[1]
datasetKey <- "fceb1041-5194-4940-967c-b0479f562a3b"

# need to add this the gbifmt package eventually 
get_mt_datasetkey <- function(datasetKey) {
  url <- paste0("https://api.gbif.org/v1/dataset/", datasetKey, "/machineTag")
  response <- httr::GET(url, httr::config(http_version = 2))
  if (httr::status_code(response) == 200) {
    httr::content(response, "parsed")
  } else {
    stop("Failed to fetch machine tags: ", httr::status_code(response))
  }
}

existing <- get_mt_datasetkey(datasetKey) |>
lapply(tibble::as_tibble) |>
dplyr::bind_rows() |>
dplyr::filter(namespace == config$machineTag$namespace & value == config$machineTag$value) 

if(nrow(existing) == 0) {
print("Creating machine tag")
create_mt(
uuid=datasetKey,
namespace=config$machineTag$namespace,
value=config$machineTag$value,
name=config$machineTag$namespace
) 
} else {
  print("Machine tag already exists")
}



