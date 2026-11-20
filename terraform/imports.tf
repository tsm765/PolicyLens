# Provider import IDs use quoted Snowflake identifiers, even for uppercase names.
# Review the full plan before any apply: an import apply also applies differences.
import {
  to = snowflake_warehouse.policylens_wh
  id = "\"POLICYLENS_WH\""
}

import {
  to = snowflake_database.policylens_db
  id = "\"POLICYLENS_DB\""
}

import {
  to = snowflake_schema.app
  id = "\"POLICYLENS_DB\".\"APP\""
}
