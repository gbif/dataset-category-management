
library(rgbif)
library(gbifmt)
library(yaml)

cats <- yaml.load_file("config.yaml")$categories

cat <- cats[1]
config <- yaml.load_file(paste0("category-configs/",cat,".yaml"))
config

from_search_query <- function(query) {
    lapply(query, function(x) { 
        rgbif::dataset_export(q=x) |>
        dplyr::select(datasetKey) |>
        dplyr::mutate(searchQuery = x) 
    }) |> 
    dplyr::bind_rows() |>
    dplyr::group_by(datasetKey) |>
    dplyr::summarise(searchQuery = toString(unique(searchQuery)))
}

from_publisher_key <- function(publisher_key) {
    lapply(publisher_key, function(x) { 
        rgbif::dataset_export(publishingOrg=x) |>
        dplyr::select(datasetKey) |>
        dplyr::mutate(publisherKey = x) 
    }) |> 
    dplyr::bind_rows() |>
    dplyr::group_by(datasetKey) |>
    dplyr::summarise(publisherKey = toString(unique(publisherKey)))
}

# keep searches and publishers
kp <- from_publisher_key(config$keep$publisherKey)
ks <- from_search_query(config$keep$searchQuery)

# exclude searches and publishers 
if(!length(config$exclude$publisherKey) == 0) {
    ep <- from_publisher_key(config$exclude$publisherKey)$datasetKey
} else {
    ep <- NULL
}
if(!length(config$exclude$searchQuery) == 0) {
    es <- from_search_query(config$exclude$searchQuery)$datasetKey
} else {
    es <- NULL
}

nrow(kp)

cand <- merge(kp, ks, by="datasetKey", all=TRUE) 

# filter out datasetKeys that are already in shell/issue_log.txt
if(file.exists("shell/issue_log.txt")) {
    logged_data <- readr::read_tsv("shell/issue_log.txt", col_names = FALSE, show_col_types = FALSE)
    if(nrow(logged_data) > 0 && nrow(cand) > 0) {
        cand <- cand[!(cand$datasetKey %in% logged_data$X1),]
    }
}

# add additional information for GitHub issue
if(nrow(cand) > 0) {
cand <- cand |> 
dplyr::mutate(title = sapply(cand$datasetKey, function(x) gsub("[\t\r\n]", "", rgbif::dataset_get(x)$title))) |>
dplyr::mutate(publisher = sapply(cand$datasetKey, function(x) rgbif::dataset_get(x)$publishingOrganizationKey)) |>
dplyr::mutate(datasetCategory = cat) 
}

# remove datasets from exclude lists 
if(!is.null(ep)) {
    cand <- cand |> dplyr::filter(!datasetKey %in% ep)
}
if(!is.null(es)) {
    cand <- cand |> dplyr::filter(!datasetKey %in% es)
}

readr::write_tsv(cand, paste0("candidate-tsv/",cat,".tsv"))


