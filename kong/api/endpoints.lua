local Errors       = require "kong.db.errors"
local utils        = require "kong.tools.utils"
local arguments    = require "kong.api.arguments"
local app_helpers  = require "lapis.application"


local kong         = kong
local escape_uri   = ngx.escape_uri
local unescape_uri = ngx.unescape_uri
local tonumber     = tonumber
local null         = ngx.null
local type         = type
local fmt          = string.format


-- error codes http status codes
local ERRORS_HTTP_CODES = {
  [Errors.codes.INVALID_PRIMARY_KEY]   = 400,
  [Errors.codes.SCHEMA_VIOLATION]      = 400,
  [Errors.codes.PRIMARY_KEY_VIOLATION] = 400,
  [Errors.codes.FOREIGN_KEY_VIOLATION] = 400,
  [Errors.codes.UNIQUE_VIOLATION]      = 409,
  [Errors.codes.NOT_FOUND]             = 404,
  [Errors.codes.INVALID_OFFSET]        = 400,
  [Errors.codes.DATABASE_ERROR]        = 500,
  [Errors.codes.INVALID_SIZE]          = 400,
  [Errors.codes.INVALID_UNIQUE]        = 400,
  [Errors.codes.INVALID_OPTIONS]       = 400,
}


local function handle_error(err_t)
  if type(err_t) ~= "table" then
    kong.log.err(err_t)
    kong.response.exit(500, { message = "An unexpected error occurred" })
  end

  if err_t.strategy then
    err_t.strategy = nil
  end

  local status = ERRORS_HTTP_CODES[err_t.code]
  if not status or status == 500 then
    return app_helpers.yield_error(err_t)
  end

  local body = utils.get_default_exit_body(status, err_t)
  return kong.response.exit(status, body)
end


local function extract_options(args, schema, context)
  local options = {
    nulls = true,
  }

  if args and schema and context then
    if schema.ttl == true and args.ttl ~= nil and (context == "insert" or
                                                   context == "update" or
                                                   context == "upsert") then
      options.ttl = tonumber(args.ttl) or args.ttl
      args.ttl = nil
    end
  end

  return options
end


local function get_page_size(args)
  local size = args.size
  if size ~= nil then
    size = tonumber(size)
    if size == nil then
      return nil, "size must be a number"
    end

    return size
  end
end


local function query_entity(context, self, db, schema, method)
  local is_insert = context == "insert"
  local is_update = context == "update" or context == "upsert"

  local args
  if is_update or is_insert then
    args = self.args.post
  else
    args = self.args.uri
  end

  local opts = extract_options(args, schema, context)
  local dao = db[schema.name]

  if is_insert then
    return dao[method or context](dao, args, opts)
  end

  if context == "page" then
    local size, err = get_page_size(args)
    if err then
      return nil, err, db[schema.name].errors:invalid_size(err)
    end

    if not method then
      return dao[method or context](dao, size, args.offset, opts)
    end

    return dao[method](dao, self.params[schema.name], size, args.offset, opts)
  end

  local key = self.params[schema.name]
  if type(key) ~= "table" then
    if type(key) == "string" then
      key = { id = unescape_uri(key) }
    else
      key = { id = key }
    end
  end

  if not utils.is_valid_uuid(key.id) then
    local endpoint_key = schema.endpoint_key
    if endpoint_key then
      local field = schema.fields[endpoint_key]
      local inferred_value = arguments.infer_value(key.id, field)
      if is_update then
        return dao[method or context .. "_by_" .. endpoint_key](dao, inferred_value, args, opts)
      end

      return dao[method or context .. "_by_" .. endpoint_key](dao, inferred_value, opts)
    end
  end

  if is_update then
    return dao[method or context](dao, key, args, opts)
  end

  return dao[method or context](dao, key, opts)
end


local function select_entity(...)
  return query_entity("select", ...)
end


local function update_entity(...)
  return query_entity("update", ...)
end


local function upsert_entity(...)
  return query_entity("upsert", ...)
end


local function delete_entity(...)
  return query_entity("delete", ...)
end


local function insert_entity(...)
  return query_entity("insert", ...)
end

local function page_collection(...)
  return query_entity("page", ...)
end


-- Generates admin api get collection endpoint functions
--
-- Examples:
--
-- /routes
-- /services/:services/routes
--
-- and
--
-- /services
local function get_collection_endpoint(schema, foreign_schema, foreign_field_name, method)
  return not foreign_schema and function(self, db, helpers)
    local data, _, err_t, offset = page_collection(self, db, schema, method)
    if err_t then
      return handle_error(err_t)
    end

    local next_page = offset and fmt("/%s?offset=%s",
                                     schema.name,
                                     escape_uri(offset)) or null

    return kong.response.exit(200, {
      data   = data,
      offset = offset,
      next   = next_page,
    })
  end or function(self, db, helpers)
    local foreign_entity, _, err_t = select_entity(self, db, foreign_schema)
    if err_t then
      return handle_error(err_t)
    end

    if not foreign_entity then
      return kong.response.exit(404, { message = "Not found" })
    end

    self.params[schema.name] = foreign_schema:extract_pk_values(foreign_entity)

    local method = method or "page_for_" .. foreign_field_name
    local data, _, err_t, offset = page_collection(self, db, schema, method)
    if err_t then
      return handle_error(err_t)
    end

    local foreign_key = self.params[foreign_schema.name]
    local next_page = offset and fmt("/%s/%s/%s?offset=%s", foreign_schema.name,
                                     foreign_key, schema.name, escape_uri(offset)) or null


    return kong.response.exit(200, {
      data   = data,
      offset = offset,
      next   = next_page,
    })
  end
end


-- Generates admin api post collection endpoint functions
--
-- Examples:
--
-- /routes
-- /services/:services/routes
--
-- and
--
-- /services
local function post_collection_endpoint(schema, foreign_schema, foreign_field_name, method)
  return function(self, db, helpers, post_process)
    if foreign_schema then
      local foreign_entity, _, err_t = select_entity(self, db, foreign_schema)
      if err_t then
        return handle_error(err_t)
      end

      if not foreign_entity then
        return kong.response.exit(404, { message = "Not found" })
      end

      self.args.post[foreign_field_name] = foreign_schema:extract_pk_values(foreign_entity)
    end

    local entity, _, err_t = insert_entity(self, db, schema, method)
    if err_t then
      return handle_error(err_t)
    end

    if post_process then
      entity, _, err_t = post_process(entity)
      if err_t then
        return handle_error(err_t)
      end
    end

    return kong.response.exit(201, entity)
  end
end


-- Generates admin api get entity endpoint functions
--
-- Examples:
--
-- /routes/:routes
-- /routes/:routes/service
--
-- and
--
-- /services/:services
local function get_entity_endpoint(schema, foreign_schema, foreign_field_name, method)
  return function(self, db, helpers)
    local entity, _, err_t
    if foreign_schema then
      entity, _, err_t = select_entity(self, db, schema)
    else
      entity, _, err_t = select_entity(self, db, schema, method)
    end

    if err_t then
      return handle_error(err_t)
    end

    if not entity then
      return kong.response.exit(404, { message = "Not found" })
    end

    if foreign_schema then
      local pk = entity[foreign_field_name]
      if not pk or pk == null then
        return kong.response.exit(404, { message = "Not found" })
      end

      self.params[foreign_schema.name] = pk

      entity, _, err_t = select_entity(self, db, foreign_schema, method)
      if err_t then
        return handle_error(err_t)
      end

      if not entity then
        return kong.response.exit(404, { message = "Not found" })
      end
    end

    return kong.response.exit(200, entity)
  end
end


-- Generates admin api put entity endpoint functions
--
-- Examples:
--
-- /routes/:routes
-- /routes/:routes/service
--
-- and
--
-- /services/:services
local function put_entity_endpoint(schema, foreign_schema, foreign_field_name, method)
  return not foreign_schema and function(self, db, helpers)
    local entity, _, err_t = upsert_entity(self, db, schema, method)
    if err_t then
      return handle_error(err_t)
    end

    if not entity then
      return kong.response.exit(404, { message = "Not found" })
    end

    return kong.response.exit(200, entity)

  end or function(self, db, helpers)
    local entity, _, err_t = select_entity(self, db, schema)
    if err_t then
      return handle_error(err_t)
    end

    if not entity then
      return kong.response.exit(404, { message = "Not found" })
    end

    local pk = entity[foreign_field_name]
    if not pk or pk == null then
      return kong.response.exit(404, { message = "Not found" })
    end

    self.params[foreign_schema.name] = pk

    entity, _, err_t = upsert_entity(self, db, foreign_schema, method)
    if err_t then
      return handle_error(err_t)
    end

    if not entity then
      return kong.response.exit(404, { message = "Not found" })
    end

    return kong.response.exit(200, entity)
  end
end


-- Generates admin api patch entity endpoint functions
--
-- Examples:
--
-- /routes/:routes
-- /routes/:routes/service
--
-- and
--
-- /services/:services
local function patch_entity_endpoint(schema, foreign_schema, foreign_field_name, method)
  return not foreign_schema and function(self, db, helpers)
    local entity, _, err_t = update_entity(self, db, schema, method)
    if err_t then
      return handle_error(err_t)
    end

    if not entity then
      return kong.response.exit(404, { message = "Not found" })
    end

    return kong.response.exit(200, entity)

  end or function(self, db, helpers)
    local entity, _, err_t = select_entity(self, db, schema)
    if err_t then
      return handle_error(err_t)
    end

    if not entity then
      return kong.response.exit(404, { message = "Not found" })
    end

    local pk = entity[foreign_field_name]
    if not pk or pk == null then
      return kong.response.exit(404, { message = "Not found" })
    end

    self.params[foreign_schema.name] = pk

    entity, _, err_t = update_entity(self, db, foreign_schema, method)
    if err_t then
      return handle_error(err_t)
    end

    if not entity then
      return kong.response.exit(404, { message = "Not found" })
    end

    return kong.response.exit(200, entity)
  end
end


-- Generates admin api delete entity endpoint functions
--
-- Examples:
--
-- /routes/:routes
-- /routes/:routes/service
--
-- and
--
-- /services/:services
local function delete_entity_endpoint(schema, foreign_schema, foreign_field_name, method)
  return not foreign_schema and  function(self, db, helpers)
    local _, _, err_t = delete_entity(self, db, schema, method)
    if err_t then
      return handle_error(err_t)
    end

    return kong.response.exit(204)

  end or function(self, db, helpers)
    local entity, _, err_t = select_entity(self, db, schema)
    if err_t then
      return handle_error(err_t)
    end

    local id = entity and entity[foreign_field_name]
    if not id or id == null then
      return kong.response.exit(404, { message = "Not found" })
    end

    return kong.response.exit(405, { message = "Method not allowed" })
  end
end


local function generate_collection_endpoints(endpoints, schema, foreign_schema, foreign_field_name)
  local collection_path
  if foreign_schema then
    collection_path = fmt("/%s/:%s/%s", foreign_schema.name, foreign_schema.name, schema.name)

  else
    collection_path = fmt("/%s", schema.name)
  end

  endpoints[collection_path] = {
    schema  = schema,
    methods = {
      --OPTIONS = method_not_allowed,
      --HEAD    = method_not_allowed,
      GET     = get_collection_endpoint(schema, foreign_schema, foreign_field_name),
      POST    = post_collection_endpoint(schema, foreign_schema, foreign_field_name),
      --PUT     = method_not_allowed,
      --PATCH   = method_not_allowed,
      --DELETE  = method_not_allowed,
    },
  }
end


local function generate_entity_endpoints(endpoints, schema, foreign_schema, foreign_field_name)
  local entity_path
  if foreign_schema then
    entity_path = fmt("/%s/:%s/%s", schema.name, schema.name, foreign_field_name)

  else
    entity_path = fmt("/%s/:%s", schema.name, schema.name)
  end

  endpoints[entity_path] = {
    schema  = foreign_schema or schema,
    methods = {
      --OPTIONS = method_not_allowed,
      --HEAD    = method_not_allowed,
      GET     = get_entity_endpoint(schema, foreign_schema, foreign_field_name),
      --POST    = method_not_allowed,
      PUT     = put_entity_endpoint(schema, foreign_schema, foreign_field_name),
      PATCH   = patch_entity_endpoint(schema, foreign_schema, foreign_field_name),
      DELETE  = delete_entity_endpoint(schema, foreign_schema, foreign_field_name),
    },
  }
end


-- Generates admin api endpoint functions
--
-- Examples:
--
-- /routes
-- /routes/:routes
-- /routes/:routes/service
-- /services/:services/routes
--
-- and
--
-- /services
-- /services/:services
local function generate_endpoints(schema, endpoints)
  -- e.g. /routes
  generate_collection_endpoints(endpoints, schema)

  -- e.g. /routes/:routes
  generate_entity_endpoints(endpoints, schema)

  for foreign_field_name, foreign_field in schema:each_field() do
    if foreign_field.type == "foreign" and not foreign_field.schema.legacy then
      -- e.g. /routes/:routes/service
      generate_entity_endpoints(endpoints, schema, foreign_field.schema, foreign_field_name)

      -- e.g. /services/:services/routes
      generate_collection_endpoints(endpoints, schema, foreign_field.schema, foreign_field_name)
    end
  end

  return endpoints
end


-- A reusable handler for endpoints that are deactivated
-- (e.g. /targets/:targets)
local not_found = {
  before = function()
    return kong.response.exit(404, { message = "Not found" })
  end
}


local Endpoints = {
  not_found = not_found,
  handle_error = handle_error,
  get_page_size = get_page_size,
  extract_options = extract_options,
  select_entity = select_entity,
  update_entity = update_entity,
  upsert_entity = upsert_entity,
  delete_entity = delete_entity,
  insert_entity = insert_entity,
  page_collection = page_collection,
  get_entity_endpoint = get_entity_endpoint,
  put_entity_endpoint = put_entity_endpoint,
  patch_entity_endpoint = patch_entity_endpoint,
  delete_entity_endpoint = delete_entity_endpoint,
  get_collection_endpoint = get_collection_endpoint,
  post_collection_endpoint = post_collection_endpoint,
}


function Endpoints.new(schema, endpoints)
  return generate_endpoints(schema, endpoints)
end


return Endpoints
