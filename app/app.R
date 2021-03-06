# Demo DataTable + postgres in Shiny
#
#----------------------------------------
# Load libraries
library(shiny)
library(DT)
library(pool)
library(DBI)
library(RPostgreSQL)
library(dplyr)
library(glue)

if(packageVersion("DT")<"0.2.30"){
  message("Inline editing requires DT version >= 0.2.30. Installing...")
  devtools::install_github('rstudio/DT')
}

if(packageVersion("glue")<"1.2.0.9000"){
  message("String interpolation implemented in glue version 1.2.0 but this version doesn't convert NA to NULL. Requires version 1.2.0.9000. Installing....")
  devtools::install_github('tidyverse/glue')
}

#----------------------------------------
# helpers.R
# Define function that updates a value in DB
# updateDB(editedValue, pool, tbl)
updateDB <- function(editedValue, pool, tbl){
  # Keep only the last modification for a cell
  editedValue <- editedValue %>% 
    group_by(row, col) %>% 
    filter(value == dplyr::last(value)| is.na(value)) %>% 
    ungroup()
  
  conn <- poolCheckout(pool)
  
  lapply(seq_len(nrow(editedValue)), function(i){
    id = editedValue$row[i]
    col = dbListFields(pool, tbl)[editedValue$col[i]]
    value = editedValue$value[i]

    query <- glue::glue_sql("UPDATE {`tbl`} SET
                          {`col`} = {value}
                          WHERE id = {id}
                          ", .con = conn)
    
    dbExecute(conn, sqlInterpolate(ANSI(), query))
  })
  
  poolReturn(conn)
  print(editedValue)  
  return(invisible())
}



#---------------------------------------- shiny
# Define pool handler by pool on global level
pool <- pool::dbPool(drv = dbDriver("PostgreSQL"),
                     dbname="demo",
                     host="localhost",
                     user= "postgres",
                     password="ava2post")

onStop(function() {
  poolClose(pool)
}) # important!

#----------------------------------------
# Define UI 
ui <- fluidPage(
  
  # Application title
  titlePanel("dbdtshiny - Inline Editing and Database Updating"),
  
  sidebarLayout(
    sidebarPanel(
      width = 2,
      helpText("This shiny app demos inline editing with 
               DataTable(DT) as frontend and postgresql as backend.
                After you double click on a cell and edit the value, 
                the Save and Cancel buttons will show up. Click on Save if
                you want to save the updated values to database; click on
                Cancel to reset."),
      uiOutput("buttons")
    ),
    mainPanel(
      tabsetPanel(
        tabPanel("View", br(), DT::dataTableOutput("mydt"))
      )
    )
  )
)
#----------------------------------------
# Define server
server <- function(input, output, session) {
  
  rvs <- reactiveValues(
    data = NA, 
    dbdata = NA,
    dataSame = TRUE,
    editedInfo = NA
  )
  
  #-----------------------------------------  
  # Generate source via reactive expression
  mysource <- reactive({
    pool %>% tbl("nasa") %>% collect()
  })
  
  # Observe the source, update reactive values accordingly
  observeEvent(mysource(), {
    
    # Lightly format data by arranging id
    # Not sure why disordered after sending UPDATE query in db    
    data <- mysource() %>% arrange(id)
    
    rvs$data <- data
    rvs$dbdata <- data
    
  })
  
  #-----------------------------------------
  # Render DT table and edit cell
  # 
  # no curly bracket inside renderDataTable
  # selection better be none
  # editable must be TRUE
  output$mydt <- DT::renderDataTable(
    rvs$data, rownames = FALSE, editable = TRUE, selection = 'none'
  )
  
  proxy3 = dataTableProxy('mydt')
  
  observeEvent(input$mydt_cell_edit, {
    
    info = input$mydt_cell_edit
    
    i = info$row
    j = info$col = info$col + 1  # column index offset by 1
    v = info$value
    
    info$value <- as.numeric(info$value)
    
    rvs$data[i, j] <<- DT::coerceValue(v, purrr::flatten_dbl(rvs$data[i, j]))
    replaceData(proxy3, rvs$data, resetPaging = FALSE, rownames = FALSE)
    
    rvs$dataSame <- identical(rvs$data, rvs$dbdata)
    
    if (all(is.na(rvs$editedInfo))) {
      rvs$editedInfo <- data.frame(info)
    } else {
      rvs$editedInfo <- dplyr::bind_rows(rvs$editedInfo, data.frame(info))
    }
    
  })
  
  
  #-----------------------------------------
  # Update edited values in db once save is clicked
  observeEvent(input$save, {
    
    updateDB(editedValue = rvs$editedInfo, pool = pool, tbl = "nasa")
    
    rvs$dbdata <- rvs$data
    rvs$dataSame <- TRUE
  })
  
  #-----------------------------------------
  # Oberve cancel -> revert to last saved version
  observeEvent(input$cancel, {
    rvs$data <- rvs$dbdata
    rvs$dataSame <- TRUE
  })
  
  #-----------------------------------------
  # UI buttons
  output$buttons <- renderUI({
    div(
      if (! rvs$dataSame) {
        span(
          actionButton(inputId = "save", label = "Save",
                       class = "btn-primary"),
          actionButton(inputId = "cancel", label = "Cancel")
        )
      } else {
        span()
      }
    )
  })
  
}

# Run the application 
shinyApp(ui = ui, server = server)

