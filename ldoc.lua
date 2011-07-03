---------------
-- ldoc, a Lua documentation generator.
-- Compatible with luadoc-style annoations, but providing
-- easier customization options. C/C++ support is provided.
-- Steve Donovan, 2011

require 'pl'

local append = table.insert
local template = require 'pl.template'
local lapp = require 'pl.lapp'

-- so we can find our private modules
app.require_here()

local args = lapp [[
ldoc, a documentation generator for Lua, vs 0.4 Beta
  -d,--dir (default docs) output directory
  -o,--output  (default 'index') output name
  -v,--verbose          verbose
  -a,--all              show local functions, etc, in docs
  -q,--quiet            suppress output
  -m,--module           module docs as text
  -s,--style (default !) directory for style sheet (ldoc.css)
  -l,--template (default !) directory for template (ldoc.ltp)
  -p,--project (default ldoc) project name
  -t,--title (default Reference) page title
  -f,--format (default plain) formatting - can be markdown or plain
  -b,--package  (default .) top-level package basename (needed for module(...))
  -x,--ext (default html) output file extension
  --dump                debug output dump
  --filter (default none) dump output as Lua data
  <file> (string) source file or directory containing source
]]

local lexer = require 'ldoc.lexer'
local doc = require 'ldoc.doc'
local lang = require 'ldoc.lang'
local Item,File,Module = doc.Item,doc.File,doc.Module
local tools = require 'ldoc.tools'
local global = require 'builtin.globals'
local KindMap = tools.KindMap

class.ModuleMap(KindMap)

function ModuleMap:_init ()
   self.klass = ModuleMap
   self.fieldname = 'section'
end

ModuleMap:add_kind('function','Functions','Parameters')
ModuleMap:add_kind('table','Tables','Fields')
ModuleMap:add_kind('field','Fields')
ModuleMap:add_kind('lfunction','Local Functions','Parameters')


class.ProjectMap(KindMap)
ProjectMap.project_level = true

function ProjectMap:_init ()
   self.klass = ProjectMap
   self.fieldname = 'type'
end

ProjectMap:add_kind('module','Modules')
ProjectMap:add_kind('script','Scripts')

------- ldoc external API ------------

-- the ldoc table represents the API available in `config.ld`.
local ldoc = {}
local add_language_extension

-- aliases to existing tags can be defined. E.g. just 'p' for 'param'
function ldoc.alias (a,tag)
   doc.add_alias(a,tag)
end

function ldoc.add_language_extension(ext,lang)
   add_language_extension(ext,lang)
end

function ldoc.add_section (name,title,subname)
   ModuleMap:add_kind(name,title,subname)
end

-- new tags can be added, which can be on a project level.
function ldoc.new_type (tag,header,project_level)
   doc.add_tag(tag,doc.TAG_TYPE,project_level)
   if project_level then
      ProjectMap:add_kind(tag,header)
   else
      ModuleMap:add_kind(tag,header)
   end
end

-- any file called 'config.ld' found in the source tree will be
-- handled specially. It will be loaded using 'ldoc' as the environment.
local function read_ldoc_config (fname)
   local directory = path.dirname(fname)
   local err
   print('reading configuration from '..fname)
   local txt,not_found = utils.readfile(fname)
   if txt then
       -- Penlight defines loadin for Lua 5.1 as well
       local chunk,err = loadin(ldoc,txt)
       if chunk then
          local ok
          ok,err = pcall(chunk)
       end
    end
   if err then print('error loading config file '..fname..': '..err) end
   return directory, not_found
end

local function quote (s)
   return "'"..s.."'"
end

------ Parsing the Source --------------
-- This uses the lexer from PL, but it should be possible to use Peter Odding's
-- excellent Lpeg based lexer instead.

local tnext = lexer.skipws

-- a pattern particular to LuaDoc tag lines: the line must begin with @TAG,
-- followed by the value, which may extend over several lines.
local luadoc_tag = '^%s*@(%a+)%s(.+)'

-- assumes that the doc comment consists of distinct tag lines
function parse_tags(text)
   local lines = stringio.lines(text)
   local preamble, line = tools.grab_while_not(lines,luadoc_tag)
   local tag_items = {}
   local follows
   while line do
      local tag,rest = line:match(luadoc_tag)
      follows, line = tools.grab_while_not(lines,luadoc_tag)
      append(tag_items,{tag, rest .. '\n' .. follows})
   end
   return preamble,tag_items
end

-- This takes the collected comment block, and uses the docstyle to
-- extract tags and values.  Assume that the summary ends in a period or a question
-- mark, and everything else in the preamble is the description.
-- If a tag appears more than once, then its value becomes a list of strings.
-- Alias substitution and @TYPE NAME shortcutting is handled by Item.check_tag
local function extract_tags (s)
   if s:match '^%s*$' then return {} end
   local preamble,tag_items = parse_tags(s)
   local strip = tools.strip
   local summary,description = preamble:match('^(.-[%.?])%s(.+)')
   if not summary then summary = preamble end
   local tags = {summary=summary and strip(summary),description=description and strip(description)}
   for _,item in ipairs(tag_items) do
      local tag,value = item[1],item[2]
      tag = Item.check_tag(tags,tag)
      value = strip(value)
      local old_value = tags[tag]
      if old_value then
         if type(old_value)=='string' then tags[tag] = List{old_value} end
         tags[tag]:append(value)
      else
         tags[tag] = value
      end
   end
   return Map(tags)
end

local quit = utils.quit


-- parses a Lua or C file, looking for ldoc comments. These are like LuaDoc comments;
-- they start with multiple '-'. (Block commments are allowed)
-- If they don't define a name tag, then by default
-- it is assumed that a function definition follows. If it is the first comment
-- encountered, then ldoc looks for a call to module() to find the name of the
-- module if there isn't an explicit module name specified.

local function parse_file(fname,lang)
   local line,f = 1
   local F = File(fname)
   local module_found, first_comment = false,true

   local tok,f = lang.lexer(fname)
   local toks = tools.space_skip_getter(tok)

    function lineno ()
        while true do
            local res = lexer.lineno(tok)
            if type(res) == 'number' then return res end
            if res == nil then return nil end
        end
    end
   function filename () return fname end

   function F:warning (msg,kind)
      kind = kind or 'warning'
      lineno() -- why is this necessary?
      lineno()
      io.stderr:write(kind..' '..fname..':'..lineno()..' '..msg,'\n')
   end

   function F:error (msg)
      self:warning(msg,'error')
      os.exit(1)
   end

   local function add_module(tags,module_found,old_style)
      tags.name = module_found
      tags.class = 'module'
      local item = F:new_item(tags,lineno())
      item.old_style = old_style
   end

   local t,v = tok()
   while t do
      if t == 'comment' then
         local comment = {}
         local ldoc_comment,block = lang:start_comment(v)
         if ldoc_comment and block then
            t,v = lang:grab_block_comment(v,tok)
         end

         if lang:empty_comment(v)  then -- ignore rest of empty start comments
            t,v = tok()
         end

         while t and t == 'comment' do
            v = lang:trim_comment(v)
            append(comment,v)
            t,v = tok()
            if t == 'space' and not v:match '\n' then
               t,v = tok()
            end
         end
         if not t then break end -- no more file!

         if t == 'space' then t,v = tnext(tok) end

         local fun_follows, tags, is_local
         if ldoc_comment or first_comment then
            comment = table.concat(comment)
            if not ldoc_comment and first_comment then
               F:warning("first comment must be a doc comment!")
               break
            end
            first_comment = false
            fun_follows, is_local = lang:function_follows(t,v,tok)
            if fun_follows or comment:find '@'then
               tags = extract_tags(comment)
               if doc.project_level(tags.class) then
                  module_found = tags.name
               end
               if tags.class == 'function' then
                  fun_follows, is_local = false, false
               end
            end
         end
         -- some hackery necessary to find the module() call
         if not module_found and ldoc_comment then
            local old_style
            module_found,t,v = lang:find_module(tok,t,v)
            -- right, we can add the module object ...
            old_style = module_found ~= nil
            if not module_found or module_found == '...' then
               if not t then quit(fname..": end of file") end -- run out of file!
               -- we have to guess the module name
               module_found = tools.this_module_name(args.package,fname)
            end
            if not tags then tags = extract_tags(comment) end
            add_module(tags,module_found,old_style)
            tags = nil
            -- if we did bump into a doc comment, then we can continue parsing it
         end

         -- end of a block of document comments
         if ldoc_comment and tags then
            local line = t ~= nil and lineno() or 666
            if t ~= nil then
               if fun_follows then -- parse the function definition
                  lang:parse_function_header(tags,tok,toks)
               else
                  lang:parse_extra(tags,tok,toks)
               end
            end
            -- local functions treated specially
            if tags.class == 'function' and (is_local or tags['local']) then
               tags.class = 'lfunction'
            end
            if tags.name then
               F:new_item(tags,line).inferred = fun_follows
            end
            if not t then break end
         end
      end
      if t ~= 'comment' then t,v = tok() end
   end
   if f then f:close() end
   return F
end

function read_file(name,lang)
   local F = parse_file(name,lang)
   F:finish()
   return F
end

--- processing command line and preparing for output ---

local CONFIG_NAME = 'config.ld'

local F
local file_list,module_list = List(),List()
module_list.by_name = {}
local multiple_files
local config_dir

local function extract_modules (F)
   for mod in F.modules:iter() do
      module_list:append(mod)
      module_list.by_name[mod.name] = mod
   end
end

local ldoc_dir = arg[0]:gsub('[^/\\]+$','')
local doc_path = ldoc_dir..'builtin/?.luadoc'


-- ldoc -m is expecting a Lua package; this converts this to a file path
if args.module then
   -- first check if we've been given a global Lua lib function
   if args.file:match '^%a+$' and global.functions[args.file] then
      args.file = 'global.'..args.file
   end
   local fullpath,mod = tools.lookup_existing_module_or_function (args.file, doc_path)
   if not fullpath then
      quit(mod)
   else
      args.file = fullpath
      args.module = mod
   end
end

-- a special case: 'ldoc .' can get all its parameters from config.ld
if args.file == '.' then
   local err
   config_dir,err = read_ldoc_config('./'..CONFIG_NAME)
   if err then quit("no "..quote(CONFIG_NAME).." found here") end
   config_is_read = true
   args.file = ldoc.file or '.'
   if args.file == '.' then
      args.file = lfs.currentdir()
   elseif type(args.file) == 'table' then
      for i,f in ipairs(args.file) do
         args.file[i] = path.abspath(f)
         print(args.file[i])
      end
   else
      args.file = path.abspath(args.file)
   end
else
   args.file = path.abspath(args.file)
end

local source_dir = args.file
if type(args.file) == 'string' and path.isfile(args.file) then
   source_dir = path.splitpath(source_dir)
end

---------- specifying the package for inferring module names --------
-- If you use module(...), or forget to explicitly use @module, then
-- ldoc has to infer the module name. There are three sensible values for
-- `args.package`:
--
--  * '.' the actual source is in an immediate subdir of the path given
--  * '..' the path given points to the source directory
--  * 'NAME' explicitly give the base module package name
--

local function setup_package_base()
   if ldoc.package then args.package = ldoc.package end
   if args.package == '.' then
      args.package = source_dir
   elseif args.package == '..' then
      args.package = path.splitpath(source_dir)
   elseif not args.package:find '[\//]' then
      local subdir,dir = path.splitpath(source_dir)
      if dir == args.package then
         args.package = subdir
      elseif path.isdir(path.join(source_dir,args.package)) then
         args.package = source_dir
      else
         quit("args.package is not the name of the source directory")
      end
   end
end

local lua, cc = lang.lua, lang.cc

local file_types = {
   ['.lua'] = lua,
   ['.ldoc'] = lua,
   ['.luadoc'] = lua,
   ['.c'] = cc,
   ['.cpp'] = cc,
   ['.cxx'] = cc,
   ['.C'] = cc
}

function add_language_extension (ext,lang)
   lang = (lang=='c' and cc) or (lang=='lua' and lua) or quit('unknown language')
   if ext:sub(1,1) ~= '.' then ext = '.'..ext end
   file_types[ext] = lang
end

local function process_file (f, file_list)
   print(f)
   local ext = path.extension(f)
   local ftype = file_types[ext]
   if ftype then
      if args.verbose then print(path.basename(f)) end
      local F = read_file(f,ftype)
      file_list:append(F)
   end
end

if type(args.file) == 'table' then
   -- this can only be set from config file so we can assume it's already read
   for _,f in ipairs(args.file) do
      if path.isdir(f) then
         local files = List(dir.getallfiles(f,'*.*'))
         for f in files:iter() do
            process_file(f, file_list)
         end
      elseif path.isfile(f) then
         process_file(f, file_list)
      else
         quit("file or directory does not exist: "..quote(f))
      end
   end
   if #file_list == 0 then quit "no source files specified" end
elseif path.isdir(args.file) then
   local files = List(dir.getallfiles(args.file,'*.*'))

   if not config_dir then
      local config_files = files:filter(function(f)
         return path.basename(f) == CONFIG_NAME
      end)
      if #config_files > 0 then
         config_dir = read_ldoc_config(config_files[1])
         if #config_files > 1 then
            print('warning: other config files found: '..config_files[2])
         end
      end
   end

   for f in files:iter() do
      process_file(f, file_list)
   end

   if #file_list == 0 then
      quit(quote(args.file).." contained no source files")
   end

elseif path.isfile(args.file) then
   -- a single file may be accompanied by a config.ld in the same dir
   if not config_dir then
      config_dir = path.dirname(args.file)
      if config_dir == '' then config_dir = '.' end
      local config = path.join(config_dir,CONFIG_NAME)
      if path.isfile(config) then
         read_ldoc_config(config)
      end
   end

   process_file(args.file, file_list)
   if #file_list == 0 then quit "unsupported file extension" end
else
   quit ("file or directory does not exist: "..quote(args.file))
end

setup_package_base()

multiple_files = #file_list > 1

local project = ProjectMap()

for F in file_list:iter() do
   extract_modules(F)
end

for mod in module_list:iter() do
   mod:resolve_references(module_list)
   project:add(mod,module_list)
end

-- the default is not to show local functions in the documentation.
if not args.all then
   for mod in module_list:iter() do
      mod:mask_locals()
   end
end

table.sort(module_list,function(m1,m2)
   return m1.name < m2.name
end)

-- ldoc -m will give a quick & dirty dump of the module's documentation;
-- using -v will make it more verbose
if args.module then
   if #module_list == 0 then quit("no modules found") end
   if args.module == true then
      F:dump(args.verbose)
   else
      local fun = module_list[1].items.by_name[args.module]
      if not fun then quit(quote(args.module).." is not part of "..quote(args.file)) end
      fun:dump(true)
   end
   return
end

if args.dump then
   for mod in module_list:iter() do
      mod:dump(true)
   end
   os.exit()
end


if args.filter ~= 'none' then
   local mod,name = tools.split_dotted_name(args.filter)
   local ok,P = pcall(require,mod)
   if not ok then quit("cannot find module "..quote(mod)) end
   local ok,f = pcall(function() return P[name] end)
   if not ok or type(f) ~= 'function' then quit("dump module: no function "..quote(name)) end

   -- clean up some redundant and cyclical references--
   module_list.by_name = nil
   for mod in module_list:iter() do
      mod.kinds = nil
      mod.file = mod.file.filename
      for item in mod.items:iter() do
         item.module = nil
         item.file = nil
         item.formal_args = nil
         item.tags['return'] = nil
      end
      mod.items.by_name = nil
   end

   local ok,err = pcall(f,module_list)
   if not ok then quit("dump failed: "..err) end
   os.exit()
end

local css, templ = 'ldoc.css','ldoc.ltp'

local function style_dir (sname)
   local style = ldoc[sname]
   local dir
   if style then
      if style == true then
         dir = config_dir
      elseif type(style) == 'string' and path.isdir(style) then
         dir = style
      else
         quit(quote(tostring(name)).." is not a directory")
      end
      args[sname] = dir
   end
end

local function override (field)
   if ldoc[field] then args[field] = ldoc[field] end
end

-- the directories for template and stylesheet can be specified
-- either by command-line '--template','--style' arguments or by 'template and
-- 'style' fields in config.ld.
-- The assumption here is that if these variables are simply true then the directory
-- containing config.ld contains a ldoc.css and a ldoc.ltp respectively. Otherwise
-- they must be a valid subdirectory.

style_dir 'style'
style_dir 'template'

-- can specify format, output, dir and ext in config.ld
override 'format'
override 'output'
override 'dir'
override 'ext'

if not args.ext:find '^%.' then
   args.ext = '.'..args.ext
end

-- '!' here means 'use same directory as ldoc.lua
local ldoc_html = path.join(ldoc_dir,'html')
if args.style == '!' then args.style = ldoc_html end
if args.template == '!' then args.template = ldoc_html end

local module_template,err = utils.readfile (path.join(args.template,templ))
if not module_template then
   quit("template not found. Use -l to specify directory containing ldoc.ltp")
end

if args.format ~= 'plain' then
   local ok,markup = pcall(require,args.format)
   if not ok then quit("cannot load formatter: "..args.format) end
   function ldoc.markup(txt)
      if txt == nil then return '' end
      txt = markup(txt)
      return (txt:gsub('^%s*<p>(.+)</p>%s*$','%1'))
   end
else
   function ldoc.markup(txt)
      return txt
   end
end

function generate_output()
   ldoc.single = not multiple_files
   local check_directory, check_file, writefile = tools.check_directory, tools.check_file, tools.writefile
   ldoc.log = print
   ldoc.kinds = project
   ldoc.css = css
   ldoc.modules = module_list
   ldoc.title = ldoc.title or args.title
   ldoc.project = ldoc.project or args.project

   local out,err = template.substitute(module_template,{
      ldoc = ldoc,
      module = ldoc.single and ldoc.modules[1] or nil
    })
   if not out then quit("template failed: "..err) end

   check_directory(args.dir)

   args.dir = args.dir .. path.sep

   check_file(args.dir..css, path.join(args.style,css))

   -- write out the module index
   writefile(args.dir..args.output..args.ext,out)

   -- write out the per-module documentation
   if not ldoc.single then
      ldoc.css = '../'..css
      ldoc.output = args.output
      for kind, modules in project() do
         kind = kind:lower()
         check_directory(args.dir..kind)
         for m in modules() do
            out,err = template.substitute(module_template,{
               module=m,
               ldoc = ldoc
            })
            if not out then
               quit('template failed for '..m.name..': '..err)
            else
               writefile(args.dir..kind..'/'..m.name..args.ext,out)
            end
         end
      end
   end
   if not args.quiet then print('output written to '..args.dir) end
end

generate_output()

if args.verbose then
   print 'modules'
   for k in pairs(module_list.by_name) do print(k) end
end


