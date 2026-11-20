# Local-only profile in ~/.snowflake/config supplies organization_name,
# account_name, and user. Supply the password outside the repository, such as
# SNOWFLAKE_PASSWORD in the current shell. MFA approval is interactive.
provider "snowflake" {
  profile       = "policylens_local"
  authenticator = "USERNAMEPASSWORDMFA"
  role          = "ACCOUNTADMIN"
}
