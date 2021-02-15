# Crystal: Economy Earning
require 'rufus-scheduler'
require 'set'

# This crystal contains the portion of Cobalt's economy features that handle awarding points for activity.
# Note: This is separate due to the expectation that it will also be extremely large.
module Bot::EconomyEarning
  extend Discordrb::EventContainer
  extend Convenience
  include Constants

  # Scheduler constant
  SCHEDULER = Rufus::Scheduler.new

  # Path to economy data folder
  ECON_DATA_PATH = "#{Bot::DATA_PATH}/economy".freeze

  # thread coordination
  DATA_LOCK = Mutex.new

  # Most activity is rewarded
  IGNORED_CHANNELS = [
    READ_ME_FIRST_CHANNEL_ID,
    ADDITIONAL_INFO_CHANNEL_ID,
    PARTNERS_CHANNEL_ID,
    QUOTEBOARD_CHANNEL_ID,
    BOT_COMMANDS_CHANNEL_ID,
    *VOICE_TEXT_CHANNELS
  ].freeze

  # Channels that have special point handling
  SPECIAL_CHAT_CHANNELS = [
    SVTFOE_DISCUSSION_ID,
    SVTFOE_GALLERY_ID,
    ORIGINAL_ART_CHANNEL_ID,
    ORIGINAL_CONTENT_CHANNEL_ID
  ].freeze

  # The minimum number of people actively voice chat required to earn points.
  MIN_VOICE_CONNECTED = 2

  #################
  ##   EVENTS    ##
  #################

  # Message event handler
  @@sent_messages = {} # map of channels to users participating
  message do |event|
    next unless event.server == SERVER
    next if event.channel == nil || IGNORED_CHANNELS.include?(event.channel.id)
    next if event.user == nil

    # special message rewards
    if SPECIAL_CHAT_CHANNELS.include?(event.channel.id)
      # do special handling
    end

    # general chat awarding
    DATA_LOCK.synchronize do
      if @@sent_messages[event.channel.id] == nil
        @@sent_messages[event.channel.id] = Set[]
      end

      @@sent_messages[event.channel.id].add(event.user.id)
    end
  end

  # Voice handler
  @@voice_connected = {} # map of channels to users participating
  voice_state_update do |event|
    next unless event.server == SERVER
    next if event.channel != nil && IGNORED_CHANNELS.include?(event.channel.id)

    DATA_LOCK.synchronize do
      # create necessary sets
      if event.old_channel != nil && @@voice_connected[event.old_channel.id] == nil
        @@voice_connected[event.old_channel.id] = Set[]
      end
      if event.channel != nil && @@voice_connected[event.channel.id] == nil
        @@voice_connected[event.channel.id] = Set[]
      end


      # user disconnected
      if event.channel == nil && event.old_channel != nil
        @@voice_connected[event.old_channel.id].delete(event.user.id)
        next # done processing
      end
      
      # safely handle weird states
      next unless event.channel != nil || event.user == nil
      
      # user switched channels
      if event.old_channel != nil and event.channel != event.old_channel
        @@voice_connected[event.old_channel.id].delete(event.user.id)
        # continue on
      end

      # remove users that have deafed themselves
      if event.deaf || event.self_deaf
        @@voice_connected[event.channel.id].delete(event.user.id)
        next # done processing
      end
      
      # user is connected and not deafened, let them gain points
      @@voice_connected[event.channel.id].add(event.user.id)
    end
  end

  ################################
  ##   RUFUS SCHEDULED EVENTS   ##
  ################################
  SCHEDULER.every '1m' do
    DATA_LOCK.synchronize do
      # reward points for voice chat, can only earn points from one channel
      already_earned_voice = Set[]
      @@voice_connected.each do |channel_id, connected|
        next unless connected.count >= MIN_VOICE_CONNECTED

        # reward points to all users connected
        connected.each do |user_id|
          next if already_earned_voice.include?(user_id)
          already_earned_voice.add(user_id)
          RewardVoiceActivity(user_id)
        end
      end

      # users earn points from the highest valued caht
      chat_earned = {}
      @@sent_messages.each do |channel_id, users|
        next if users.empty?

        # reward max message value points to each user
        users.each do |user_id|
          cur_value = chat_earned[user_id]
          cur_value = 0 if cur_value == nil

          new_value = GetChatReward(channel_id)
          chat_earned[user_id] = [cur_value, new_value].max
        end
      end

      # award points to each user participating in chat
      chat_earned.each do |user, earnings|
        Bot::Bank::Deposit(user, earnings)
      end

      # clear message values, will be repopulated
      @@sent_messages.clear()
    end
  end

  ##########################
  ##   HELPER FUNCTIONS   ##
  ##########################
  module_function
  # Get the Starbucks value for the specified action.
  # @param [String] action_name The action's name.
  # @return [Integer] Startbucks earned by the action. 
  def GetActionEarnings(action_name)
    points_yaml = YAML.load_data!("#{ECON_DATA_PATH}/point_values.yml")
    return points_yaml[action_name]
  end

  # Reward a user for voice activity.
  # @param [Integer] user_id User to reward
  def RewardVoiceActivity(user_id)
    reward = GetActionEarnings('activity_voice_chat')
    Bot::Bank::Deposit(user_id, reward) if reward != nil
  end

  # Get the reward value for chatting in the specified channel.
  # @param [Integer] channel_id The channel id the activity occurred on.
  # @param [Integer] user_id    The user's id.
  # @param [Integer] is_voice   Is this a voice channel?
  # @return [Integer] The points earned by the activity.
  def GetChatReward(channel_id)
    reward = GetActionEarnings('activity_text_chat')
    return reward != nil ? reward : 0
  end
end