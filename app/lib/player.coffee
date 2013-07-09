RoomJsObject = require('./object').RoomJsObject

# a RoomJsPlayer is just a slightly more specialized RoomJsObject
exports.RoomJsPlayer = class RoomJsPlayer extends RoomJsObject

  constructor: (player, db) ->
    super player, db
    @username = player.username
    @password = player.password
    @player = true
    @programmer = player.programmer
    @lastActivity = if player.lastActivity? then new Date player.lastActivity else undefined
    @socket = null

  authenticates: (username, passwordHash) ->
    @username == username and @password == passwordHash

  online: -> @socket?

  send: (msg) ->
    if @socket?
      @socket.emit 'output', "#{msg}"
      true
    else
      false

  broadcast: (msg) ->
    loc = @location()
    if loc?
      for o in loc.contents()
        o.send msg if o.player and o != @
      true
    else
      false

  input: (msg, callback) ->
    if @socket?
      @socket.emit 'request_input', "#{msg}", (response) =>
        try
          callback?.call null, response
        catch error
          errorStr = error.toString()
          source = 'input callback'
          @send "{inverse bold red|#{errorStr} in '#{source}'}"
      true
    else
      false

  setProgrammer: (programmer) ->
    @programmer = !!programmer

  toString: ->
    "[##{@id} #{@name} (#{@username})]"