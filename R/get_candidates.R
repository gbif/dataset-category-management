
library(rgbif)
library(yaml)

# Parse command line arguments
args <- commandArgs(trailingOnly = TRUE)

# Get all categories from config
all_cats <- yaml.load_file("config.yaml")$categories

# If a category is provided as argument, use only that one; otherwise use all
if (length(args) > 0) {
    requested_cat <- args[1]
    if (requested_cat %in% all_cats) {
        cats <- requested_cat
        cat("Running for single category:", requested_cat, "\n")
    } else {
        stop(paste("Error: Category '", requested_cat, "' not found. Available categories:", 
                   paste(all_cats, collapse = ", ")))
    }
} else {
    cats <- all_cats
    cat("Running for all categories:", paste(cats, collapse = ", "), "\n")
}

from_search_query <- function(query) {
    # Handle empty or NULL input
    if (is.null(query) || length(query) == 0) {
        return(data.frame(datasetKey = character(0), searchQuery = character(0), stringsAsFactors = FALSE))
    }
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
    # Handle empty or NULL input
    if (is.null(publisher_key) || length(publisher_key) == 0) {
        return(data.frame(datasetKey = character(0), publisherKey = character(0), stringsAsFactors = FALSE))
    }
    lapply(publisher_key, function(x) { 
        rgbif::dataset_export(publishingOrg=x) |>
        dplyr::select(datasetKey) |>
        dplyr::mutate(publisherKey = x) 
    }) |> 
    dplyr::bind_rows() |>
    dplyr::group_by(datasetKey) |>
    dplyr::summarise(publisherKey = toString(unique(publisherKey)))
}

from_machine_tag <- function(namespace) {
    # Function to page through GBIF machine tags using gbifmt::get_mt()
    # and extract dataset keys and machine tag values
    
    limit <- 100
    offset <- 0
    all_data <- data.frame()
    
    repeat {
        cat("Fetching machine tags with offset:", offset, "limit:", limit, "\n")
        
        # Get machine tags using gbifmt with pagination
        mt_data <- gbifmt::get_mt(namespace, limit = limit, offset = offset)
        
        # Check if we got any results
        if (is.null(mt_data) || nrow(mt_data) == 0) {
            cat("No more results found. Total datasets collected:", nrow(all_data), "\n")
            break
        }
        
        cat("Collected", nrow(mt_data), "machine tags from offset", offset, ". Total so far:", nrow(all_data) + nrow(mt_data), "\n")
        
        # Combine with existing data
        all_data <- rbind(all_data, mt_data)
        
        # Check if we've reached the end (less than limit returned)
        if (nrow(mt_data) < limit) {
            cat("Reached end of records. Total datasets:", nrow(all_data), "\n")
            break
        }
        
        # Update offset for next page
        offset <- offset + limit
        
        # Add small delay to be respectful to the API
        Sys.sleep(0.1)
    }
    
    # Return processed data frame with required columns
    if (nrow(all_data) > 0) {
        # Extract uuid (datasetKey) and use machine tag value as searchQuery
        result <- all_data |>
            dplyr::select(uuid, value) |>
            dplyr::rename(datasetKey = uuid, searchQuery = value) |>
            dplyr::mutate(
                # Sanitize searchQuery to make it GitHub-safe
                searchQuery = gsub('["{},:]', '_', searchQuery),  # Replace problematic chars with underscore
                searchQuery = gsub('_+', '_', searchQuery),       # Replace multiple underscores with single
                searchQuery = gsub('^_|_$', '', searchQuery)      # Remove leading/trailing underscores
            )
        
        return(result)
    } else {
        return(data.frame(datasetKey = character(0), searchQuery = character(0), stringsAsFactors = FALSE))
    }
}

# https://api.gbif.org/v1/dataset/c779b049-28f3-4daf-bbf4-0a40830819b6/gridded

# Process each category
for(cat in cats) {
    cat("Processing category:", cat, "\n")
    config <- yaml.load_file(paste0("category-configs/",cat,".yaml"))
    
    namespace <- config$machineTag$namespace
    if(!is.null(namespace)) {
        cat("Category", cat, "is machineTag generated. Using machine tag namespace.\n")
        # Get the machine tag namespace from config
        cand <- from_machine_tag(namespace)
        
        # Add category information and required fields
        if(nrow(cand) > 0) {
            cand <- cand |>
                dplyr::mutate(
                    publisherKey = NA_character_,
                    title = sapply(cand$datasetKey, function(x) gsub("[\t\r\n]", "", rgbif::dataset_get(x)$title)),
                    publisher = sapply(cand$datasetKey, function(x) rgbif::dataset_get(x)$publishingOrganizationKey),
                    datasetCategory = cat
                )
        }
    } else {
        # keep searches and publishers
        kp <- from_publisher_key(config$keep$publisherKey)
        print(config$keep$searchQuery)
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

        cat("Number of datasets from publisher keys:", nrow(kp), "\n")
        
        cand <- merge(kp, ks, by="datasetKey", all=TRUE) 
        
        # remove datasets from exclude lists 
        if(!is.null(ep)) {
            cand <- cand |> dplyr::filter(!datasetKey %in% ep)
        }
        if(!is.null(es)) {
            cand <- cand |> dplyr::filter(!datasetKey %in% es)
        }
        
        # add additional information for GitHub issue
        if(nrow(cand) > 0) {
            cand <- cand |> 
            dplyr::mutate(title = sapply(cand$datasetKey, function(x) gsub("[\t\r\n]", "", rgbif::dataset_get(x)$title))) |>
            dplyr::mutate(publisher = sapply(cand$datasetKey, function(x) rgbif::dataset_get(x)$publishingOrganizationKey)) |>
            dplyr::mutate(datasetCategory = cat) 
        }
    }

    cat("Final number of candidates for", cat, ":", nrow(cand), "\n")
    
    # Print table of results showing number of datasets per searchQuery
    if(nrow(cand) > 0 && !is.null(cand$searchQuery)) {
        cat("\n--- Summary of datasets per searchQuery for", cat, "category ---\n")
        
        # Split searchQuery values that may contain multiple comma-separated queries
        search_query_expanded <- data.frame(
            datasetKey = character(),
            searchQuery = character(),
            stringsAsFactors = FALSE
        )
        
        for(i in 1:nrow(cand)) {
            if(!is.na(cand$searchQuery[i])) {
                queries <- trimws(unlist(strsplit(cand$searchQuery[i], ",")))
                for(query in queries) {
                    search_query_expanded <- rbind(search_query_expanded, 
                        data.frame(datasetKey = cand$datasetKey[i], 
                                 searchQuery = query, 
                                 stringsAsFactors = FALSE))
                }
            }
        }
        
        # Create summary table
        if(nrow(search_query_expanded) > 0) {
            summary_table <- search_query_expanded |>
                dplyr::group_by(searchQuery) |>
                dplyr::summarise(dataset_count = dplyr::n_distinct(datasetKey), .groups = 'drop') |>
                dplyr::arrange(desc(dataset_count))
            
            print(summary_table)
            cat("\n")
        } else {
            cat("No search queries found in candidates.\n\n")
        }
    }
    
    readr::write_tsv(cand, paste0("candidate-tsv/",cat,".tsv"))
}


