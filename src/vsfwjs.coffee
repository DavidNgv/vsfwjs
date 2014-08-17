# **vsfw** is a [CoffeeScript](http://coffeescript.org) DSL-ish interface
# for building web apps on the [node.js](http://nodejs.org) runtime,
# integrating [express](http://expressjs.com), [socket.io](http://socket.io)
# and other best-of-breed libraries.

vsfw = version: '0.0.1'

codename = 'You can\'t do that on stage anymore'

log = console.log
fs = require 'fs'
path = require 'path'
uuid = require 'node-uuid'
uglify = require 'uglify-js'

vendor = (name) ->
  fs.readFileSync(path.join(__dirname,'..','vendor',name)).toString()

jquery = vendor 'jquery.js'
jquery_minified = vendor 'jquery.min.js'
sammy = vendor 'sammy.js'
sammy_minified = vendor 'sammy.min.js'
socketjs = vendor 'socket.io.js'

socketio_key = '__session'

# Soft dependencies:
jsdom = null
gzippo = null
express_partials = null
coffee_css = null

# CoffeeScript-generated JavaScript may contain anyone of these; when we
# "rewrite" a function (see below) though, it loses access to its parent scope,
# and consequently to any helpers it might need. So we need to reintroduce
# these helpers manually inside any "rewritten" function.
coffeescript_helpers = """
  var __slice = Array.prototype.slice;
  var __hasProp = Object.prototype.hasOwnProperty;
  var __bind = function(fn, me){
    return function(){ return fn.apply(me, arguments); };
  };
  var __extends = function(child, parent) {
    for (var key in parent) {
      if (__hasProp.call(parent, key)) child[key] = parent[key];
    }
    function ctor() { this.constructor = child; }
    ctor.prototype = parent.prototype;
    child.prototype = new ctor;
    child.__super__ = parent.prototype;
    return child;
  };
  var __indexOf = Array.prototype.indexOf || function(item) {
    for (var i = 0, l = this.length; i < l; i++) {
      if (this[i] === item) return i;
    } return -1; };
""".replace /\n/g, ''

minify = (js) ->
  result = uglify.minify js, fromString:true
  result.code

# Shallow copy attributes from `sources` (array of objects) to `recipient`.
# Does NOT overwrite attributes already present in `recipient`.
copy_data_to = (recipient, sources) ->
  for obj in sources
    for k, v of obj
      recipient[k] = v unless recipient[k]
  return

# Flatten array recursively (copied from Express's utils.js)
flatten = (arr, ret) ->
  ret ?= []
  for o in arr
    if Array.isArray o
      flatten o, ret
    else
      ret.push o
  ret

# vsfw FS
vsfw_fs = {}

native_name = (p) ->
  p.replace /\/\.vsfw-[^\/]+/, ''

# Patch Node.js's `fs`.
native_readFileSync = fs.readFileSync
native_readFile = fs.readFile

native_array = (args...) ->
  args[0] = native_name args[0]
  args

fs.readFileSync = (p,encoding) ->
  vsfw_fs[p] ? native_readFileSync.apply fs, native_array arguments...

fs.readFile = (p,encoding,callback) ->
  view = vsfw_fs[p]
  if view
    if typeof encoding is 'function' and not callback?
      callback = encoding
    callback null, view
  else
    native_readFile.apply fs, native_array arguments...

native_existsSync = fs.existsSync ? path.existsSync
native_exists = fs.exists ? path.exists

path.existsSync = fs.existsSync = (p) ->
  vsfw_fs[p]? or native_existsSync.apply fs, native_array arguments...

path.exists = fs.exists = (p,callback) ->
  if vsfw_fs[p]?
    callback true
  else
    native_exists.apply fs, native_array arguments...


# Express must first be called after we modify the `fs` module.
express = require 'express'
socketio = require 'socket.io'

# Takes in a function and builds express/socket.io apps based on the rules
# contained in it.
vsfw.app = (func,options={}) ->
  context = {id: uuid.v4(), vsfw, express}

  real_root = path.dirname(module.parent.filename)
  root =  path.join real_root, ".vsfw-#{context.id}"

  # Storage for user-provided stuff.
  # Views are kept at the module level.
  ws_handlers = {}
  helpers = {}
  postrenders = {}
  partials = {}

  app = context.app = express()
  if options.https?
    context.server = require('https').createServer options.https, app
  else
    context.server = require('http').createServer app
  if options.disable_io
    io = null
  else
    io = context.io = socketio.listen(context.server)

  # Reference to the zappa client, the value will be set later.
  client = null
  client_bundled = null
  client_bundle_simple = null

  # Tracks if the vsfw middleware is already mounted (`@use 'vsfw'`).
  vsfw_used = no

  # vsfw's default settings.
  app.set 'view engine', 'coffee'
  app.engine 'coffee', coffeecup_adapter

  # Sets default view dir to @root
  app.set 'views', path.join(root, '/views')

  # Location of vsfw-specific URIs.
  app.set 'vsfw_prefix', '/vsfw'

  for verb in ['get', 'post', 'put', 'del', 'all']
    do (verb) ->
      context[verb] = (args...) ->
        arity = args.length
        if arity > 1
          route
            verb: verb
            path: args[0]
            middleware: flatten args[1...arity-1]
            handler: args[arity-1]
        else
          for k, v of arguments[0]
            route verb: verb, path: k, handler: v
        return

  context.client = (obj) ->
    context.use 'vsfw' unless vsfw_used
    for k, v of obj
      js = ";vsfw.run(#{v});"
      js = minify(js) if app.settings['minify']
      route verb: 'get', path: k, handler: js, contentType: 'js'
    return

  context.coffee = (obj) ->
    for k, v of obj
      js = ";#{coffeescript_helpers}(#{v})();"
      js = minify(js) if app.settings['minify']
      route verb: 'get', path: k, handler: js, contentType: 'js'
    return

  context.js = (obj) ->
    for k, v of obj
      js = String(v)
      js = minify(js) if app.settings['minify']
      route verb: 'get', path: k, handler: js, contentType: 'js'
    return

  context.css = (obj) ->
    for k, v of obj
      if typeof v is 'object'
        coffee_css ?= require 'coffee-css'
        css = coffee_css.compile v
      else
        css = String(v)
      route verb: 'get', path: k, handler: css, contentType: 'css'
    return

  context.with = (obj) ->
    vsfw_with =
      css: (modules) ->
        if typeof modules is 'string'
          modules = [modules]
        for name in modules
          module = require(name)
          context[name] = (obj) ->
            for k, v of obj
              module.render v, filename: k, (err, css) ->
                throw err if err
                route verb: 'get', path: k, handler: css, contentType: 'css'
            return
        return

    for k,v of obj
      if vsfw_with[k]
        vsfw_with[k] v

  context.helper = (obj) ->
    for k, v of obj
      helpers[k] = v
    return

  context.postrender = (obj) ->
    jsdom = require 'jsdom'
    for k, v of obj
      postrenders[k] = v
    return

  context.on = (obj) ->
    for k, v of obj
      ws_handlers[k] = v
    return

  context.view = (obj) ->
    for k, v of obj
      ext = path.extname k
      zappa_fs[k] = v
      if not ext
        ext = '.' + app.get 'view engine'
        zappa_fs[k+ext] = v
    return

  context.engine = (obj) ->
    for k, v of obj
      app.engine k, v
    return

  context.set = (obj) ->
    for k, v of obj
      app.set k, v
    return

  context.enable = ->
    app.enable i for i in arguments
    return

  context.disable = ->
    app.disable i for i in arguments
    return

  context.use = ->
    vsfw_middleware =
    # Connect `static` middlewate uses fs.stat().
      static: (options) ->
        if typeof options is 'string'
          options = path: options
        options ?= {}
        p = options.path ? path.join(real_root, '/public')
        delete options.path
        express.static(p,options)
      staticGzip: (options) ->
        if typeof options is 'string'
          options = path: options
        options ?= {}
        p = options.path ? path.join(real_root, '/public')
        gzippo ?= require 'gzippo'
        gzippo.staticGzip(p, options)
        return
      vsfw: ->
        vsfw_used = yes
        (req, res, next) ->
          send = (code) ->
            res.contentType 'js'
            res.send code
          if req.method.toUpperCase() isnt 'GET' then next()
          else
            vsfw_prefix = app.settings['vsfw_prefix']
            switch req.url
              when vsfw_prefix+'/Vsfw.js' then send client_bundled
              when vsfw_prefix+'/Vsfw-simple.js' then send client_bundle_simple
              when vsfw_prefix+'/vsfw.js' then send client
              when vsfw_prefix+'/jquery.js' then send jquery_minified
              when vsfw_prefix+'/sammy.js' then send sammy_minified
              else next()
          return
      partials: (maps = {}) ->
        express_partials ?= require 'zappajs-partials'
        partials = express_partials()
        partials.register 'coffee', coffeecup_adapter.render
        for k,v of maps
          partials.register k, v
        partials
      session: (options) ->
        context.session_store = options.store
        express.session options

    use = (name, arg = null) ->
      if vsfw_middleware[name]
        app.use vsfw_middleware[name](arg)
      else if typeof express[name] is 'function'
        app.use express[name](arg)

    for a in arguments
      switch typeof a
        when 'function' then app.use a
        when 'string' then use a
        when 'object'
          if a.stack? or a.route?
            app.use a
          else
            use k, v for k, v of a
    return

  context.configure = (p) ->
    if typeof p is 'function' then app.configure p
    else app.configure k, v for k, v of p
    return

  context.settings = app.settings
  context.locals = app.locals

  context.shared = (obj) ->
    context.use 'vsfw' unless vsfw_used
    for k, v of obj
      js = ";vsfw.run(#{v});"
      js = minify(js) if app.settings['minify']
      route verb: 'get', path: k, handler: js, contentType: 'js'
      v.apply context
    return

  context.include = (p) ->
    sub = if typeof p is 'string' then require path.join(real_root, p) else p
    sub.include.apply context

  apply_helpers = (ctx) ->
    for name, helper of helpers
      do (name, helper) ->
        if typeof helper is 'function'
          ctx[name] = ->
            helper.apply ctx, arguments
        else
          ctx[name] = helper
        return
    ctx

  # Local socket
  request_socket = (req) ->
    socket_id = req.session?.__socket?['__local']?.id
    socket_id and io?.sockets.socket socket_id, true

  # The callback will receive (err,session).
  socket_session = (socket,cb) ->
    socket.get socketio_key, (err,data) ->
      if err
        return cb err
      data = JSON.parse data
      if data.id?
        context.session_store.get data.id, cb
      else
        cb err

  context.param = (obj) ->
    build = (callback) ->
      (req,res,next,p) ->
        ctx =
          app: app
          settings: app.settings
          locals: res.locals
          request: req
          req: req
          query: req.query
          params: req.params
          body: req.body
          session: req.session
          response: res
          res: res
          next: next
          param: p
        apply_helpers ctx
        callback.call ctx, req, res, next, p

    for k, v of obj
      @app.param k, build v

    return

  # Register a route with express.
  route = (r) ->
    r.middleware ?= []

    # Rewrite middleware
    r.middleware = r.middleware.map (f) ->
      (req,res,next) ->
        ctx =
          app: app
          settings: app.settings
          locals: res.locals
          request: req
          req: req
          query: req.query
          params: req.params
          body: req.body
          session: req.session
          response: res
          res: res
          next: next

        apply_helpers ctx

        if app.settings['databag']
          ctx.data = {}
          copy_data_to ctx.data, [req.query, req.params, req.body]

        f.call ctx, req, res, next

    if typeof r.handler is 'string'
      app[r.verb] r.path, r.middleware, (req, res) ->
        res.contentType r.contentType if r.contentType?
        res.send r.handler
        return
    else
      app[r.verb] r.path, r.middleware, (req, res, next) ->
        ctx =
          app: app
          settings: app.settings
          locals: res.locals
          request: req
          req: req
          query: req.query
          params: req.params
          body: req.body
          session: req.session
          response: res
          res: res
          next: next
          send: -> res.send.apply res, arguments
          json: -> res.json.apply res, arguments
          jsonp: -> res.jsonp.apply res, arguments
          redirect: -> res.redirect.apply res, arguments
          format: -> res.format.apply res, arguments
          render: ->
            if typeof arguments[0] isnt 'object'
              render.apply @, arguments
            else
              for k, v of arguments[0]
                render.apply @, [k, v]
            return
          emit: ->
            socket = request_socket req
            if socket?
              if typeof arguments[0] isnt 'object'
                socket.emit.apply socket, arguments
              else
                for k, v of arguments[0]
                  socket.emit.apply socket, [k, v]
            return

        render = (name,opts = {},fn) ->

          report = fn ? (err,html) ->
            if err
              next err
            else
              res.send html

          # Make sure the second arg is an object.
          if typeof opts is 'function'
            fn = opts
            opts = {}

          if app.settings['databag']
            opts.params = data

          if not opts.postrender?
            postrender = report
          else
            postrender = (err, str) ->
              if err then return report err
              # Apply postrender before sending response.
              jsdom.env html: str, src: [jquery], done: (err, window) ->
                if err then return report err
                ctx.window = window
                rendered = postrenders[opts.postrender].apply ctx, [window.$]

                doctype = (window.document.doctype or '') + "\n"
                html = doctype + window.document.documentElement.outerHTML
                report null, html
              return

          res.render.call res, name, opts, postrender

        apply_helpers ctx

        if app.settings['databag']
          ctx.data = {}
          copy_data_to ctx.data, [req.query, req.params, req.body]

        if app.settings['x-powered-by']
          res.setHeader 'X-Powered-By', "Zappa #{zappa.version}"

        result = r.handler.call ctx, req, res, next

        res.contentType(r.contentType) if r.contentType?
        if typeof result is 'string' then res.send result
        else return result

  # Register socket.io handlers.
  io?.sockets.on 'connection', (socket) ->
    c = {}

    build_ctx = ->
      ctx =
        app: app
        io: io
        settings: app.settings
        locals: app.locals
        socket: socket
        id: socket.id
        client: c
        join: (room) ->
          socket.join room
        leave: (room) ->
          socket.leave room
        emit: ->
          if typeof arguments[0] isnt 'object'
            socket.emit.apply socket, arguments
          else
            for k, v of arguments[0]
              socket.emit.apply socket, [k, v]
          return
        broadcast: ->
          broadcast = socket.broadcast
          if typeof arguments[0] isnt 'object'
            broadcast.emit.apply broadcast, arguments
          else
            for k, v of arguments[0]
              broadcast.emit.apply broadcast, [k, v]
          return
        broadcast_to: (room, args...) ->
          room = io.sockets.in room
          if typeof args[0] isnt 'object'
            room.emit.apply room, args
          else
            for k, v of args[0]
              room.emit.apply room, [k, v]
          return
        session: -> socket_session socket, arguments...

      apply_helpers ctx
      ctx

    ctx = build_ctx()
    ws_handlers.connection.apply(ctx) if ws_handlers.connection?

    socket.on 'disconnect', ->
      ctx = build_ctx()
      ws_handlers.disconnect.apply(ctx) if ws_handlers.disconnect?

    for name, h of ws_handlers
      do (name, h) ->
        if name isnt 'connection' and name isnt 'disconnect'
          socket.on name, (data, ack) ->
            ctx = build_ctx()
            ctx.data = data
            ctx.ack = ack
            h.call ctx, data, ack
        return
    return

  # Go!
  func.apply context

  # The stringified vsfw client.
  client = require('./client').build(vsfw.version, app.settings)
  client = ";#{coffeescript_helpers}(#{client})();"
  client_bundle_simple =
    if io?
      jquery + socketjs + client
    else
      jquery + client
  client_bundled =
    if io?
      jquery + socketjs + sammy + client
    else
      jquery + sammy + client

  if app.settings['minify']
    client = minify client
    client_bundle_simple = minify client_bundle_simple
    client_bundled = minify client_bundled

  if app.settings['default layout']
    context.view layout: ->
      extension = (path,ext) ->
        if path.substr(-(ext.length)).toLowerCase() is ext.toLowerCase()
          path
        else
          path + ext
      doctype 5
      html ->
        head ->
          title @title if @title
          if @scripts
            for s in @scripts
              script src: extension s, '.js'
          script(src: extension @script, '.js') if @script
          if @stylesheets
            for s in @stylesheets
              link rel: 'stylesheet', href: extension s, '.css'
          link(rel: 'stylesheet', href: extension @stylesheet, '.css') if @stylesheet
          style @style if @style
        body @body

  if io?
    vsfw_prefix = app.settings['vsfw_prefix']
    context.get vsfw_prefix+'/socket/:channel_name/:socket_id', ->
      if @session?
        channel_name = @params.channel_name
        socket_id = @params.socket_id

        @session.__socket ?= {}

        if @session.__socket[channel_name]?
          # Client (or hijacker) trying to re-key.
          @send error:'Channel already assigned', channel_name: channel_name
        else
          key = uuid.v4() # used for socket 'authorization'

          # Update the Express session store
          @session.__socket[channel_name] =
            id: socket_id
            key: key

          # Update the Socket.IO store
          io_client = io.sockets.store.client(socket_id)
          io_data = JSON.stringify
            id: @req.sessionID
            key: key
          io_client.set socketio_key, io_data

          # Let the client know which key to use.
          @send channel_name: channel_name, key: key
      else
        @send error:'No session'
      return

  context

# vsfw.run [host,] [port,] [{options},] root_function
# Takes a function and runs it as a vsfw app. Optionally accepts a port
# number, and/or a hostname (any order). The hostname must be a string, and
# the port number must be castable as a number.

vsfw.run = ->
  host = null
  port = 3000
  root_function = null
  options =
    disable_io: false

  for a in arguments
    switch typeof a
      when 'string'
        if isNaN( (Number) a ) then host = a
        else port = (Number) a
      when 'number' then port = a
      when 'function' then root_function = a
      when 'object'
        for k, v of a
          switch k
            when 'host' then host = v
            when 'port' then port = v
            when 'disable_io' then options.disable_io = v
            when 'https' then options.https = v

  vsapp = vsfw.app(root_function,options)
  app = vsapp.app

  express_ready = ->
    log 'Express server listening on port %d in %s mode',
      vsapp.server.address()?.port, app.settings.env
    log "vSoft Framework #{vsfw.version} \"#{codename}\" orchestrating the show"

  if host
    vsapp.server.listen port, host, express_ready
  else
    vsapp.server.listen port, express_ready

  vsapp

# Creates a vsfw view adapter for templating engine `engine`. This adapter
# can be used with `context.engine` or `context.use partials:`
# and creates params "shortcuts".
#
# vsfw, by default, automatically sends all request params to templates,
# but inside the `params` local.
#
# This adapter adds a "root local" for each of these params, *only*
# if a local with the same name doesn't exist already, *and* the name is not
# in the optional blacklist.
#
# The blacklist is useful to prevent request params from triggering unset
# template engine options.
#
# If `engine` is a string, the adapter will use `require(engine)`. Otherwise,
# it will assume the `engine` param is an object with a `compile` function.
#
# Return an Express 2.x as well as an Express 3.x compatible object.
# The Express 2.x object supports both `compile` and `render`.
vsfw.adapter = (engine, options = {}) ->
  options.blacklist ?= []
  engine = require(engine) if typeof engine is 'string'
  compile = (template, data) ->
    template = engine.compile(template, data)
    (data) ->
      # Merge down `@params` into `@`
      # Bonus: if `databag` is enabled, `@params` will be the complete databag.
      for k, v of data.params
        if typeof data[k] is 'undefined' and k not in options.blacklist
          data[k] = v
      template(data)
  render = (template,data) ->
    template = compile template, data
    template data
  # Express 3.x object:
  renderFile = (name,data,fn) ->
    try
      template = fs.readFileSync(name,'utf8')
      template = compile template, data
    catch err
      return fn err
    fn null, template data
  # Express 2.x extensions:
  renderFile.compile = compile
  renderFile.render = render
  renderFile


coffeecup_adapter = vsfw.adapter 'coffeecup',
  blacklist: ['format', 'autoescape', 'locals', 'hardcode', 'cache']