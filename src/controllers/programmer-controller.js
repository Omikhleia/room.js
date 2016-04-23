const bunyan = require('bunyan');
const { filter } = require('fuzzaldrin-plus');
const BaseChildController = require('./base-child-controller');
const serialize = require('../lib/serialize');
const print = require('../lib/print');
const rewriteEval = require('../lib/rewrite-eval');
const { bgRed } = require('../lib/colors');

class ProgrammerController extends BaseChildController {
  get logger() {
    return this.parent.logger.child({ user: this.user.id, player: this.playerId });
  }

  onEval(input) {
    try {
      const code = rewriteEval(input, this.playerId);
      const filename = `Eval::${this.playerId}`;

      this.logger.debug({ code }, 'eval');

      const retVal = this.world.run(code, filename);

      this.emit('output', print(retVal, 1));
    } catch (err) {
      this.emit('output', bgRed(this.formatError(err)));
      this.logger.warn({ err: bunyan.stdSerializers.err(err) }, 'error running eval code');
    }
  }

  // TODO: this is incredibly innefficient, but works for now
  onSearch(query, done) {
    const candidates = [];

    this.world.all().forEach(object => {
      Reflect.ownKeys(object).forEach(key => {
        const value = object[key];
        if (value && typeof value === 'function') {
          const searchStr = `${object.id}.${key}`;
          const objectId = object.id;
          if (value.verb) {
            candidates.push({ searchStr, objectId, verb: key });
          } else {
            candidates.push({ searchStr, objectId, function: key });
          }
        }
      });
    });

    const results = filter(candidates, query, { key: 'searchStr', maxResults: 50 });
    done(results);
  }

  onGetVerb({ objectId, name }, done) {
    const object = this.world.get(objectId);
    if (!object) { done(void 0); return; }
    const verb = object[name];
    if (!verb || !verb.verb) { done(void 0); return; }
    const verbDescriptor = serialize(verb);
    verbDescriptor.code = verbDescriptor.verb;
    verbDescriptor.name = name;
    delete verbDescriptor.verb;
    done({ objectId, verb: verbDescriptor });
  }

  onGetFunction({ objectId, name }, done) {
    const object = this.world.get(objectId);
    if (!object) { done(void 0); return; }
    const func = object[name];
    if (!func || !func.source) { done(void 0); return; }
    done({ objectId, src: func.source, name });
  }

  onSaveVerb({ objectId, verb }, done) {
    const dbObject = this.db.findById(objectId);
    if (!dbObject) { done('no such object'); return; }

    const { name, pattern, dobjarg, preparg, iobjarg, code } = verb;
    dbObject.properties[name] = { verb: code, pattern, dobjarg, preparg, iobjarg };

    done('saved');
  }

  onSaveFunction({ objectId, src, name }, done) {
    const dbObject = this.db.findById(objectId);
    if (!dbObject) { done('no such object'); return; }

    dbObject.properties[name] = { function: src };

    done('saved');
  }
}

module.exports = ProgrammerController;