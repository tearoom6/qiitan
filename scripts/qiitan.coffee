# Description:
#   notify you of updates in Qiita.
#
# Dependencies:
#   "cron": "1.1.0"
#   "redis": "2.4.2"
#   "node-rest-client": "1.8.0"
#
# Configuration:
#   SLACK_CHANNEL_NAME
#   QIITA_ACCESS_TOKEN
#   REDIS_URL
#
# Commands:
#   None
#
# Author:
#   tearoom6
#
CronJob = require('cron').CronJob
Redis = require('redis')
Client = require('node-rest-client').Client;


class QiitaClient
  @URL_MY_ITEMS      = 'https://qiita.com/api/v2/authenticated_user/items'
  @URL_ITEM_STOCKERS = 'https://qiita.com/api/v2/items/${itemId}/stockers'
  @DEFAULT_PER_PAGE  = 100

  constructor: (@token) ->
    @client = new Client()
    @header = Authorization: "Bearer #{@token}"

  myItems: (page, perPage, callback) ->
    args =
      parameters:
        page: page
        perPage: perPage
      headers:
        @header
    @client.get QiitaClient.URL_MY_ITEMS, args, (data, response) ->
      callback page, perPage, data

  allMyItems: (thisObj, callback, page = 1, perPage = QiitaClient.DEFAULT_PER_PAGE, allData = []) ->
    args =
      parameters:
        page: page
        per_page: perPage
      headers:
        thisObj.header
    thisObj.client.get QiitaClient.URL_MY_ITEMS, args, (data, response) ->
      allData = allData.concat data
      page += 1
      if data.length == perPage
        thisObj.allMyItems thisObj, callback, page, perPage, allData
      else
        callback allData

  itemStockers: (itemId, page, perPage, callback) ->
    args =
      path:
        itemId: itemId
      parameters:
        page: page
        per_page: perPage
      headers:
        @header
    @client.get QiitaClient.URL_ITEM_STOCKERS, args, (data, response) ->
      callback itemId, page, perPage, data

  allItemStockers: (thisObj, itemId, callback, page = 1, perPage = QiitaClient.DEFAULT_PER_PAGE, allData = []) ->
    args =
      path:
        itemId: itemId
      parameters:
        page: page
        perPage: perPage
      headers:
        thisObj.header
    thisObj.client.get QiitaClient.URL_ITEM_STOCKERS, args, (data, response) ->
      allData = allData.concat data
      page += 1
      if data.length == perPage
        thisObj.allItemStockers thisObj, itemId, callback, page, perPage, allData
      else
        callback allData


class DataStore
  @KEY_LOCK     = 'QIITAN:LOCK'
  @KEY_USERS    = 'QIITAN:USERS'
  @KEY_STOCKERS = 'QIITAN:STOCKERS'
  @connectionPool = {}

  constructor: (@redisUrl) ->
    return if @client = DataStore.connectionPool[@redisUrl]
    @client = Redis.createClient(@redisUrl)
    DataStore.connectionPool[@redisUrl] = @client

  disconnect: () ->
    @client.quit()

  isLocked: (callback) ->
    @client.get DataStore.KEY_LOCK, (err, data) ->
      callback data == '1'

  lock: () ->
    @client.set DataStore.KEY_LOCK, '1', (err, res) -> {}

  unlock: () ->
    @client.del DataStore.KEY_LOCK, (err, res) -> {}

  userIds: (callback) ->
    @client.keys "#{DataStore.KEY_USERS}:*", (err, data) ->
      userIds = key.replace("#{DataStore.KEY_USERS}:", '') for key in data
      callback data

  user: (userId, callback) ->
    @client.hgetall "#{DataStore.KEY_USERS}:#{user.id}", (err, data) ->
      callback data

  addUser: (user) ->
    @client.hmset "#{DataStore.KEY_USERS}:#{user.id}", user, (err, res) -> {}

  stockerIds: (itemId, callback) ->
    @client.smembers "#{DataStore.KEY_STOCKERS}:#{itemId}", (err, data) ->
      callback itemId, data

  addStockerId: (itemId, userId) ->
    @client.sadd "#{DataStore.KEY_STOCKERS}:#{itemId}", userId, (err, res) -> {}


module.exports = (robot) ->
  channel = process.env.SLACK_CHANNEL_NAME
  accessToken = process.env.QIITA_ACCESS_TOKEN
  redisUrl = process.env.REDIS_URL
  cronTime = process.env.CRON_TIME

  sendToSlack = (channel, title, msg, color) ->
    data =
      content:
        pretext:  title
        text:     msg
        fallback: msg
        color:    color
      channel:    channel
      username:   'Qiita'
    robot.emit 'slack.attachment', data

  checkNewStocker = (qiitaClient, dataStore, item, newStockerCallback) ->
    dataStore.stockerIds item.id, (itemId, storedStockerIds) ->
      storedStockerIds = [] unless storedStockerIds
      qiitaClient.allItemStockers qiitaClient, itemId, (stockers) ->
        for stocker in stockers
          if stocker.id not in storedStockerIds
            newStockerCallback(item, stocker)

  checkAllItems = (postSlackFlg = true) ->
    robot.logger.info "Job checkAllItems started. postSlack: #{postSlackFlg}."
    qiita = new QiitaClient(accessToken)
    dataStore = new DataStore(redisUrl)
    dataStore.isLocked (isLocked) ->
      return if isLocked
      dataStore.lock()
      dataStore.userIds (storedUserIds) ->
        storedUserIds = [] unless storedUserIds
        qiita.allMyItems qiita, (items) ->
          for item in items
            checkNewStocker qiita, dataStore, item, (item, stocker) ->
              robot.logger.info "New stock found on item: #{item.id}."
              dataStore.addStockerId item.id, stocker.id
              dataStore.addUser stocker if stocker.id not in storedUserIds
              if postSlackFlg
                sendToSlack channel, '投稿がストックされました:+1:',
                    "#{item.title}\n#{item.url}",
                    '#41ab5d'
          dataStore.unlock()

  # init job
  checkAllItems(false)

  # cron job
  job = new CronJob
    cronTime: cronTime
    onTick: () ->
      checkAllItems()
    start: false
  job.start()

