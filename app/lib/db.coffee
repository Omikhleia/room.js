fs = require 'fs'
_ = require 'underscore'
EventEmitter = require('events').EventEmitter

log4js = require './logger'
logger = log4js.getLogger 'db'

mooUtil = require './util'

RoomJsObject = require('./object').RoomJsObject
RoomJsPlayer = require('./player').RoomJsPlayer

# some constants
NO_MATCH = 0
EXACT_MATCH = 1
PARTIAL_MATCH = 2

# A Db is a collection of RoomJsObjects
module.exports = class Db extends EventEmitter

  objects: {}
  players: []

  constructor: (@filename, @getContext) ->
    if fs.existsSync @filename
      {nextId: @_nextId, objects: dbObjects} = JSON.parse fs.readFileSync @filename
    else
      {nextId: @_nextId, objects: dbObjects} = JSON.parse fs.readFileSync 'db.seed.json'

    startTime = mooUtil.tstart()

    for id, dbObject of dbObjects
      if dbObject.player
        newMooObj = new RoomJsPlayer dbObject, @
      else
        newMooObj = new RoomJsObject dbObject, @
      @objects[parseInt(dbObject.id)] = newMooObj
      if newMooObj.player
        @players.push newMooObj
    @specials()
    logger.info "#{@filename} loaded in #{mooUtil.tend startTime}" if not @quiet

    @saveInterval = setInterval @save, 5*60*1000

    process.on 'exit', => @exit()

  exit: ->
    for player in @players
      if player.socket?
        player.socket.emit 'output', '{red|Server shutting down.}'
        # player.socket.disconnect()
    @saveSync()

  blankObject: (id, name) ->
    x =
      id: id
      parent_id: null
      name: name
      aliases: []
      location_id: null
      contents_ids: []
      player: false
      programmer: false
      properties: []
      verbs: []
    new RoomJsObject x, @

  specials: ->
    @objects[-1] = @blankObject -1, 'nothing'
    @objects[-2] = @blankObject -2, 'ambiguous_match'
    @objects[-3] = @blankObject -3, 'failed_match'
    @nothing = @objects[-1]
    @ambiguous_match = @objects[-2]
    @failed_match = @objects[-3]
    @sys = @objects[0]

    @nothing.send = (msg) ->
      logger.debug "$nothing got message: #{msg}"

  save: =>
    startTime = mooUtil.tstart()
    fs.writeFile '_' + @filename, @serialize(), (err) =>
      throw err if err
      fs.rename '_' + @filename, @filename, (err) =>
        throw err if err
        logger.info "#{@filename} saved in #{mooUtil.tend startTime}" if not @quiet

  saveSync: ->
    startTime = mooUtil.tstart()
    fs.writeFileSync '_' + @filename, @serialize()
    fs.renameSync '_' + @filename, @filename
    logger.info "#{@filename} saved in #{mooUtil.tend startTime}" if not @quiet

  serialize: ->
    # don't save the special objects
    objects = _.clone(@objects)
    delete objects[-1]
    delete objects[-2]
    delete objects[-3]
    JSON.stringify {nextId: @_nextId, objects: objects}

  findById: (id) ->
    if @objects[id]? then @objects[id] else null

  findByNum: (numStr) ->
    @findById parseInt numStr.match(/^#([0-9]+)$/)?[1]

  aliasFor: (id) ->
    @globalAliases()[id]

  # find the objects matched by the command
  matchObjects: (player, command) ->
    dobj: if command.dobjstr? then @findObject command.dobjstr, player else @nothing
    iobj: if command.iobjstr? then @findObject command.iobjstr, player else @nothing

  # search string can be:
  # 'me', 'here'
  # or an object name or alias, in which case we search "nearby"
  findObject: (search, player) ->
    return player if search == 'me'
    return player.location() if search == 'here'
    #return @findByNum search if search.match /^#[0-9]+$/
    @findNearby search, player

  # find objects "nearby"
  # i.e. objects the player is holding, or objects in the room
  findNearby: (search, player) ->
    return @failed_match if search == ''

    searchItems = player.contents().concat player.location().contents().filter (o) -> o != player
    matches = searchItems.map (item) -> [item.matches(search), item]
    exactMatches = matches.filter (match) -> match[0] == EXACT_MATCH
    partialMatches = matches.filter (match) -> match[0] == PARTIAL_MATCH

    if exactMatches.length == 1
      return exactMatches[0][1]
    else if exactMatches.length > 1
      return @ambiguous_match

    if partialMatches.length == 1
      return partialMatches[0][1]
    else if partialMatches.length > 1
      return @ambiguous_match

    return @failed_match

  # return a list of matched objects for moo-side use
  mooMatch: (search, player) =>
    return [] if search == ''

    searchItems = player.contents().concat player.location().contents().filter (o) -> o != player
    matches = searchItems.map (item) -> [item.matches(search), item]
    exactMatches = matches.filter (match) -> match[0] == EXACT_MATCH
    partialMatches = matches.filter (match) -> match[0] == PARTIAL_MATCH

    if exactMatches.length == 1
      return [exactMatches[0][1]]
    else if exactMatches.length > 1
      return exactMatches.map (match) -> match[1]

    if partialMatches.length == 1
      return [partialMatches[0][1]]
    else if partialMatches.length > 1
      return partialMatches.map (match) -> match[1]

    return []

  matchVerb: (player, command, objects) ->
    if (verb = player.findVerb command, objects)
      self = player
    else if (verb = player.location()?.findVerb command, objects)
      self = player.location()
    else if (verb = objects.dobj?.findVerb command, objects)
      self = objects.dobj
    else if (verb = objects.iobj?.findVerb command, objects)
      self = objects.iobj
    if verb and not verb.hidden
      verb: verb
      self: self
    else
      null

  objectsAsArray: ->
    for id,object of @objects
      object

  globalAliases: ->
    @sys.properties.filter((prop) -> prop.value._mooObject?).reduce(((map, prop) ->
      map[prop.value._mooObject] = '$' + prop.key
      map
    ), {})

  list: ->
    objectsArray = @objectsAsArray()
    objectsArray[0...objectsArray.length-3]

  search: (search) ->
    regex = new RegExp "#{search}", 'i'
    @list().filter (object) ->
      !!object.name.match regex

  usernameTaken: (username) ->
    !!(@players.filter (player) -> player.username == username).length

  playerNameTaken: (name) ->
    !!(@players.filter (player) -> player.name == name).length

  createNewPlayer: (name, username, password, programmer = false) ->
    nextId = @nextId()

    object =
      id: nextId
      parent_id: null
      name: name
      aliases: []
      location_id: null
      contents_ids: []
      username: username
      password: password
      player: true
      programmer: programmer
      properties: []
      verbs: []
      lastActivity: (new Date()).toString()

    newPlayer = new RoomJsPlayer object, @

    @objects[nextId] = newPlayer
    @players.push newPlayer

    @emit 'objectCreated', nextId

    newPlayer

  createNewObject: (name) ->
    nextId = @nextId()
    @objects[nextId] = @blankObject nextId, name
    @emit 'objectCreated', nextId
    @objects[nextId]

  # create a clone of this object with copies of all it's properties and verbs
  clone: (object, newName, newAliases) ->
    if not (newName? and newName.toString?)
      throw new Error "Invalid name for new object"
    for alias in newAliases
      if not (alias? and alias.toString?)
        throw new Error "Invalid alias '#{alias}'"
    nextId = @nextId()
    rawObject = JSON.parse JSON.stringify object
    rawObject.id = nextId
    rawObject.parent_id = object.parent_id
    rawObject.name = newName
    rawObject.aliases = newAliases
    newObject = new RoomJsObject rawObject, @
    newObject.moveTo object.location()
    @objects[nextId] = newObject
    @emit 'objectCreated', nextId
    newObject

  # Create a child of object
  # this child will inherit any of it's parent's properties and verbs
  createChild: (object, newName, newAliases = []) ->
    if not (newName? and newName.toString?)
      throw new Error "Invalid name for new object"
    for alias in newAliases
      if not (alias? and alias.toString?)
        throw new Error "Invalid alias '#{alias}'"
    nextId = @nextId()
    rawObject = JSON.parse JSON.stringify object
    rawObject.properties = []
    rawObject.verbs = []
    rawObject.id = nextId
    rawObject.parent_id = object.id
    rawObject.name = newName
    rawObject.aliases = newAliases
    newObject = new RoomJsObject rawObject, @
    newObject.moveTo object.location()
    @objects[nextId] = newObject
    @emit 'objectCreated', nextId
    newObject

  rm: (id) ->
    if id > -1 and @findById(id)?
      object = @findById id
      if object.children().length > 0
        throw new Error 'That object cannot be removed because it has children'
      object.moveTo null
      if @objects[id].player
        @players = @players.filter (p) -> p.id != id
      delete @objects[id]
      @emit 'objectDeleted', id
      true
    else
      false

  nextId: -> @_nextId++