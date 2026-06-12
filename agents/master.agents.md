# Spatial De-identification 

## NEMESIS

### Objective
Any combination of categorical variables should generate categories where there are at least 2 unique zip codes or 2 unique counties each from 2 different states, so that we cannot identify State-Zip or State-County combinations.

Each cell passes if (≥2 unique ZIPs from each of ≥2 states, i.e. ≥4 unique ZIPs total) OR (≥2 unique counties from each of ≥2 states, i.e. ≥4 unique counties total).

### Datasets
Stored under the ~/data folder
- County-level data: county_data
- Zip-level data: zip_data

### Deriving Categorical Variables
For continuous variables, start with different quantiles (e.g., 10th, 25th, 50th, 75th, and 90th percentiles) to create categories. Then, check the distribution of zip codes and counties within each category. If any category has fewer than 2 unique zip codes or counties from two different states each, adjust the quantiles or merge categories until the requirement is met.

For binary variables, ensure that each category (0 and 1) has at least 2 unique zip codes or counties each from at least two states. If not, consider combining the binary variable with another variable to create a new categorical variable that meets the requirement.

For ordinal variables, ensure that only consecutive categories are combined to maintain the order. Check the distribution of zip codes and counties within each category and adjust as necessary to meet the requirement.

### Best Possible Subset

1. All combinations of derived categorical variables from ### Derived Categorical Variables should meet the ### Objective. This means that for every combination of categorical variables, there should be at least 2 unique zip codes from each of at least 2 different states (≥4 unique ZIPs total), or at least 2 unique counties from each of at least 2 different states (≥4 unique counties total), in each category.

2. Find the largest subset of categorical variables that meets this requirement. This may involve iteratively testing combinations of variables and adjusting the categories until the optimal subset is identified. Re-coarsen bins during the subset search to fit more variables in.

3. Please create a table:
- 1 row per categorization approach for each variable (value: iteration number)
- 1 column per variable in county_data and zip_data (value: categories used as string)
- 1 column for the type of search (value: county + zip, county, zip)
- 1 column for the number of identifiable combinations

**Please feel free to write, re-write and overwrite temporary files to path_temporary_files**
- Name files originating from a .R file with the first seven characters of the file name and a descriptive suffix, e.g., `plan_derived_bins.csv`.

Priority:
- Combinations of two or more variables from both County + Zip
- Combinations of two or more variables from Zip
- Combinations of two or more variables from County

### County-Zip Crosswalk
Use the County-Zip crosswalk to identify the unique zip codes and counties associated with each category of the derived categorical variables. This will help in assessing whether the categories meet the spatial de-identification requirement.

File path: path_crosswalk_files
File name: COUNTY_ZIP_122025.xlsx (don't use any of the RATIO measures, use the state based on the first two digits of the county FIPS code)