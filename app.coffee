fs = require 'fs'

log4js = require './app/lib/logger'
serverLogger = log4js.getLogger 'server'
socketLogger = log4js.getLogger 'socket'

require './app/lib/process'
require './app/lib/pid'
config = require './app/config/app'

if config.socket? then require './app/lib/socket'

start = new Date

express = require 'express'

# create and configure the express app
module.exports = app = express()
require('./app/config/express')(app)
env = app.settings.env

# create the http and socket.io server
server = require('http').createServer app
io = require('socket.io').listen server, logger: socketLogger, 'log level': log4js.levels[config.logLevel]

# set up web controller
require('./app/controllers/index')(app)

# db needs a reference to context, but context needs db to initialize
context = null
getContext = -> context

# load the room.js database
Db = require './app/lib/db'
db = new Db config.dbFile, getContext

# create the context to run eval code and verbs in
Context = require './app/lib/context'
context = new Context db

# set up socket controllers
Client = require './app/controllers/client'
io.of('/client').on 'connection', (socket) ->
  socketLogger.info "new client connection"
  new Client db, context, socket

Editor = require './app/controllers/editor'
io.of('/editor').on 'connection', (socket) ->
  socketLogger.info "new editor connection"
  new Editor db, socket

# delete the socket file if it exists (from a previous crash)
if config.socket? and fs.existsSync config.socket
  fs.unlinkSync config.socket

# start listening
server.listen app.settings.port, ->
  if config.socket? and fs.existsSync config.socket
    fs.chmodSync config.socket, '777'

  verb = db.sys.findVerbByName 'server_started'
  if verb?
    context.runVerb null, verb, db.sys

  time = new Date - start
  serverLogger.info "room.js server started on port/socket #{app.settings.port} (#{env} mode) in #{time}ms running on node.js #{process.versions.node}"