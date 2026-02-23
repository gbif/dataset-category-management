
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

filter_by_description <- function(cand, category) {
    # Filter candidates based on whether searchQuery terms appear in title or description
    # Skip filtering if there's no searchQuery column or if it's all NA
    if(is.null(cand$searchQuery) || all(is.na(cand$searchQuery))) {
        cat("No search queries to filter by, keeping all candidates.\n")
        return(cand)
    }
    
    if(nrow(cand) == 0) {
        return(cand)
    }
    
    cat("Filtering candidates by checking if search terms appear in title or description...\n")
    initial_count <- nrow(cand)
    
    # Add description column by fetching from GBIF
    cat("Fetching descriptions for", nrow(cand), "datasets...\n")
    descriptions <- sapply(cand$datasetKey, function(x) {
        desc <- rgbif::dataset_get(x)$description
        if(is.null(desc)) return("")
        return(tolower(gsub("[\t\r\n]", " ", desc)))
    })
    
    cand$description <- descriptions
    
    # Filter: keep only if at least one search term appears in title or description
    keep_rows <- sapply(1:nrow(cand), function(i) {
        if(is.na(cand$searchQuery[i])) return(TRUE)  # Keep if no search query
        
        # Get all search terms (comma-separated)
        search_terms <- trimws(unlist(strsplit(cand$searchQuery[i], ",")))
        title_lower <- tolower(cand$title[i])
        desc_lower <- cand$description[i]
        
        # Check if any search term appears in title or description
        any(sapply(search_terms, function(term) {
            grepl(tolower(term), title_lower, fixed = TRUE) || 
            grepl(tolower(term), desc_lower, fixed = TRUE)
        }))
    })
    
    cand_filtered <- cand[keep_rows, ]
    
    # Log filtered-out datasets to checked_log.txt to avoid re-checking them
    filtered_out <- cand[!keep_rows, ]
    if(nrow(filtered_out) > 0) {
        checked_log_file <- "shell/checked_log.txt"
        checked_entries <- data.frame(
            datasetKey = filtered_out$datasetKey,
            category = category,
            stringsAsFactors = FALSE
        )
        
        # Append to checked_log.txt
        if(file.exists(checked_log_file)) {
            readr::write_tsv(checked_entries, checked_log_file, append = TRUE, col_names = FALSE)
        } else {
            readr::write_tsv(checked_entries, checked_log_file, col_names = FALSE)
        }
        cat("Added", nrow(filtered_out), "filtered datasets to checked_log.txt\n")
    }
    
    # Remove the description column as it's no longer needed
    cand_filtered$description <- NULL
    
    filtered_count <- nrow(cand_filtered)
    removed_count <- initial_count - filtered_count
    cat("Filtered out", removed_count, "datasets where search terms don't appear in title or description.\n")
    cat("Remaining candidates:", filtered_count, "\n")
    
    return(cand_filtered)
}

# https://api.gbif.org/v1/dataset/c779b049-28f3-4daf-bbf4-0a40830819b6/gridded

# Read issue log to skip already processed datasets
issue_log_file <- "shell/issue_log.txt"
already_processed <- data.frame(datasetKey = character(0), category = character(0), stringsAsFactors = FALSE)
if(file.exists(issue_log_file)) {
    already_processed <- readr::read_tsv(issue_log_file, col_names = c("datasetKey", "category"), show_col_types = FALSE)
    cat("Loaded", nrow(already_processed), "already processed datasets from issue log.\n")
}

# Read checked log to skip already checked and filtered datasets
checked_log_file <- "shell/checked_log.txt"
already_checked <- data.frame(datasetKey = character(0), category = character(0), stringsAsFactors = FALSE)
if(file.exists(checked_log_file)) {
    already_checked <- readr::read_tsv(checked_log_file, col_names = c("datasetKey", "category"), show_col_types = FALSE)
    cat("Loaded", nrow(already_checked), "already checked (filtered) datasets from checked log.\n")
}

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
            
            # Remove datasets already processed for this category
            already_in_log <- already_processed |> dplyr::filter(category == cat)
            if(nrow(already_in_log) > 0) {
                initial_count <- nrow(cand)
                cand <- cand |> dplyr::filter(!datasetKey %in% already_in_log$datasetKey)
                cat("Skipped", initial_count - nrow(cand), "datasets already in issue log for", cat, "\n")
            }
            
            # Remove datasets already checked and filtered out for this category
            already_in_checked <- already_checked |> dplyr::filter(category == cat)
            if(nrow(already_in_checked) > 0) {
                initial_count <- nrow(cand)
                cand <- cand |> dplyr::filter(!datasetKey %in% already_in_checked$datasetKey)
                cat("Skipped", initial_count - nrow(cand), "datasets already in checked log for", cat, "\n")
            }
            
            # Filter by description/title
            cand <- filter_by_description(cand, cat)
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
        
        # Remove datasets already processed for this category
        already_in_log <- already_processed |> dplyr::filter(category == cat)
        if(nrow(already_in_log) > 0) {
            initial_count <- nrow(cand)
            cand <- cand |> dplyr::filter(!datasetKey %in% already_in_log$datasetKey)
            cat("Skipped", initial_count - nrow(cand), "datasets already in issue log for", cat, "\n")
        }
        
        # Remove datasets already checked and filtered out for this category
        already_in_checked <- already_checked |> dplyr::filter(category == cat)
        if(nrow(already_in_checked) > 0) {
            initial_count <- nrow(cand)
            cand <- cand |> dplyr::filter(!datasetKey %in% already_in_checked$datasetKey)
            cat("Skipped", initial_count - nrow(cand), "datasets already in checked log for", cat, "\n")
        }
        
        # add additional information for GitHub issue
        if(nrow(cand) > 0) {
            cand <- cand |> 
            dplyr::mutate(title = sapply(cand$datasetKey, function(x) gsub("[\t\r\n]", "", rgbif::dataset_get(x)$title))) |>
            dplyr::mutate(publisher = sapply(cand$datasetKey, function(x) rgbif::dataset_get(x)$publishingOrganizationKey)) |>
            dplyr::mutate(datasetCategory = cat)
            
            # Filter by description/title
            cand <- filter_by_description(cand, cat)
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


