rm(list = ls());gc();source(".Rprofile")


county_data = read_csv("data/ktdat13_county.csv")
zip_data = read_csv("data/ktdat13_zip_v2.csv")

county_vars = c("RUCC_2023","OBESITY","BPHIGH","HIGHCHOL","ISOLATION",
                "STROKE","COPD","CASTHMA","median_income","HI_coverage","no_HS_rate",
              "UE_rate")

zip_vars = c("PrimaryRUCA","RPL_THEME1","RPL_THEME2","RPL_THEME3","RPL_THEME4","RPL_THEME5","near_walmart")


binary_vars = c("near_walmart")
ordinal_vars = c("RUCC_2023","PrimaryRUCA")
