This is a pilot project filling the category field in the registry of GBIF datasets with the appropriate `DatasetCategory` vocabulary.  

https://registry.gbif.org/vocabulary/DatasetCategory

## editing yaml configs

Within the `category-configs` folder, each yaml file represents a search configuration for a specific `DatasetCategory`.

The files list the search terms and other patterns used to generate candidate datasets for that category. 

## workflow for dealing with generated issues 

> Do not create issues manually. Allow github actions to create the issues. 

Each candidate dataset will get one issue per category. When an issue is **closed**, it is considered to not be in that category. When an issue is labeled with `add-category`, it is considered to be in that category. After which the `add-category` label is added, GitHub actions will automatically insert in the registry the category specified in the category config. The issue will also be closed automatically. So **do not** close the issue manually after adding the `add-category` label. Only close issues manually if you want to indicate that the dataset does not belong to that category.

If you want to automatically label issues with a certain label, you add that label to `yaml` config under `autoLabel`. Each time GitHub actions runs, it add the `add-category` labels specified in `autoLabel` to all open issues. 

## supported categories

Currently we only support one category for testing:

* eDNA

We are also expected to support the following categories in the future:

* CitizenScience
* BusinessSector 






