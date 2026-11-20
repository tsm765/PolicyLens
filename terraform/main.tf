resource "snowflake_warehouse" "policylens_wh" {
  name                                = "POLICYLENS_WH"
  warehouse_type                      = "STANDARD"
  warehouse_size                      = "X-SMALL"
  generation                          = "1"
  auto_suspend                        = 60
  auto_resume                         = "true"
  comment                             = "Compute warehouse for PolicyLens"
  enable_query_acceleration           = "true"
  query_acceleration_max_scale_factor = 8
  min_cluster_count                   = 1
  max_cluster_count                   = 1
  scaling_policy                      = "STANDARD"

  lifecycle {
    prevent_destroy = true
  }
}

resource "snowflake_database" "policylens_db" {
  name         = "POLICYLENS_DB"
  is_transient = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "snowflake_schema" "app" {
  name                = "APP"
  database            = snowflake_database.policylens_db.name
  is_transient        = "false"
  with_managed_access = "false"

  lifecycle {
    prevent_destroy = true
  }
}
