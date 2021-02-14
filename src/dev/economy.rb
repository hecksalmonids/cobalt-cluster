# Crystal: Economy
require 'rufus-scheduler'
require 'date'

# This crystal contains Cobalt's economy features (i.e. any features related to Starbucks)
module Bot::Economy
  extend Discordrb::Commands::CommandContainer
  extend Discordrb::EventContainer
  include Constants
  include Convenience
  
  # Scheduler constant
  SCHEDULER = Rufus::Scheduler.new

  # User last checkin time, used to prevent checkin in more than once a day
  # { user_id, checkin_timestamp }
  USER_CHECKIN_TIME = DB[:econ_user_checkin_time]

  # Path to economy data folder
  ECON_DATA_PATH = "#{Bot::DATA_PATH}/economy".freeze

  ##########################
  ##   HELPER FUNCTIONS   ##
  ##########################

  # Determine how many Starbucks the user gets for checking in.
  def self.GetUserCheckinValue(user_id)
    user = DiscordUser.new(user_id)
    role_yaml_id = nil
    case Convenience::GetHighestLevelRoleId(user)
    when BEARER_OF_THE_WAND_POG_ROLE_ID
      role_yaml_id = "checkin_bearer"
    when MEWMAN_MONARCH_ROLE_ID
      role_yaml_id = "checkin_monarch"
    when MEWMAN_NOBLE_ROLE_ID
      role_yaml_id = "checkin_noble"
    when MEWMAN_KNIGHT_ROLE_ID
      role_yaml_id = "checkin_knight"
    when MEWMAN_SQUIRE_ROLE_ID
      role_yaml_id  = "checkin_squire"
    when MEWMAN_CITIZEN_ROLE_ID
      role_yaml_id = "checkin_citizen"
    when VERIFIED_ROLE_ID
      role_yaml_id = "checkin_verified"
    when INVALID_ROLE_ID
      role_yaml_id = "checkin_new"    
    end

    if role_yaml_id == nil
      raise RuntimeError, "Unexpected role ID received, there may be a new role that needs to be accounted for by checkin!"
    end

    return Bot::Bank::AppraiseItem(role_yaml_id)
  end

  # Determine how long the user has to wait until their next checkin.
  # Zero if they can checkin now
  def self.GetTimeUntilNextCheckin(user_id)
    last_timestamp = USER_CHECKIN_TIME[user_id: user_id]
    return 0 if last_timestamp == nil || last_timestamp.first == nil

    last_timestamp = last_timestamp[:checkin_timestamp]
    last_datetime = Bot::Timezone::GetTimestampInUserLocal(user_id, last_timestamp)
    today_datetime = Bot::Timezone::GetUserToday(user_id)
    return 0 if last_datetime < today_datetime

    tomorrow_datetime = today_datetime + 1
    return tomorrow_datetime.to_time.to_i - Time.now.to_i
  end

  # Determine how long the user has to wait until their next checkin.
  def self.GetTimeUntilNextCheckinString(user_id)
    seconds = GetTimeUntilNextCheckin(user_id)
    
    return "now" if seconds <= 0

    msg = ""
    if seconds > 60*60
      hours = seconds / (60*60)
      msg = "#{hours}h, " 
      seconds -= (hours*60*60)
    end

    if seconds > 60
      minutes = seconds / 60
      msg += "#{minutes}m, "
      seconds -= (minutes*60)
    end
    
    if seconds > 0  
      msg += "#{seconds}s, "
    end

    return msg[0..-3]
  end

  # Get the role id for the given role item id.
  def self.GetRoleForItemID(role_item_id)
    case role_item_id
    when Bot::Inventory::GetItemID('role_color_obsolete_orange')
      role_id = OBSOLETE_ORANGE_ROLE_ID
    when Bot::Inventory::GetItemID('role_color_breathtaking_blue')
      role_id = BREATHTAKING_BLUE_ROLE_ID
    when Bot::Inventory::GetItemID('role_color_retro_red')
      role_id = RETRO_RED_ROLE_ID
    when Bot::Inventory::GetItemID('role_color_lullaby_lavender')
      role_id = LULLABY_LAVENDER_ROLE_ID
    when Bot::Inventory::GetItemID('role_color_whitey_white')
      role_id = WHITEY_WHITE_ROLE_ID
    when Bot::Inventory::GetItemID('role_color_marvelous_magenta')
      role_id = MARVELOUS_MAGENTA_ROLE_ID
    when Bot::Inventory::GetItemID('role_color_shallow_yellow')
      role_id = SHALLOW_YELLOW_ROLE_ID
    when Bot::Inventory::GetItemID('role_override_citizen')
      role_id = OVERRIDE_MEWMAN_CITIZEN_ROLE_ID
    when Bot::Inventory::GetItemID('role_override_squire')
      role_id = OVERRIDE_MEWMAN_SQUIRE_ROLE_ID
    when Bot::Inventory::GetItemID('role_override_knight')
      role_id = OVERRIDE_MEWMAN_KNIGHT_ROLE_ID
    when Bot::Inventory::GetItemID('role_override_noble')
      role_id = OVERRIDE_MEWMAN_NOBLE_ROLE_ID
    when Bot::Inventory::GetItemID('role_override_noble')
      role_id = OVERRIDE_MEWMAN_MONARCH_ROLE_ID
    else 
      raise ArgumentError, "Invalid role received from inventory!"
      return nil
    end

    return role_id
  end

  # Get the user's rented role or nil if they don't have one.
  def self.GetUserRentedRoleItem(user_id)
    override_role_type = Bot::Inventory::GetValueFromCatalogue('item_type_role_override')
    color_role_type = Bot::Inventory::GetValueFromCatalogue('item_type_role_color')
    roles = Bot::Inventory::GetInventory(user_id, override_role_type)
    roles.push(*Bot::Inventory::GetInventory(user_id, color_role_type))
    return roles.empty? ? nil : roles[0]
  end

  ################################
  ##   RUFUS SCHEDULED EVENTS   ##
  ################################
  SCHEDULER.every '1h' do
    # check for expired roles for each user
    users = Bot::Inventory::GetUsersWithInventory()
    users.each do |user_id|
      # skip if user isn't renting a role
      role_item = GetUserRentedRoleItem(user_id)
      next if role_item == nil
      
      # skip if not expired
      next unless role_item.expiration != nil && Time.now.to_i >= role_item.expiration

      # see if they can afford to renew, remove the role otherwise
      owner = DiscordUser.new(role_item.owner_user_id)
      role_maintain_cost = Bot::Bank::AppraiseItem('rentarole_maintain')
      if Bot::Bank::Withdraw(owner.id, role_maintain_cost)
        Bot::Inventory::RenewItem(role_item.entry_id)
      else 
        role_id = GetRoleForItemID(role_item.item_id)
        owner.user.remove_role(role_id, "#{owner.mention} could not afford to renew role!")
        Bot::Inventory::RemoveItem(role_item.entry_id)

        # send the user a dm letting them know they lost their role
        user = DiscordUser.new(role_item.owner_user_id)
        if user != nil

          user.user.dm.send_embed do |embed|
            embed.author = {
                name: STRING_BANK_NAME,
                icon_url: IMAGE_BANK
            }

            embed.color = COLOR_EMBED
            embed.title = "Role Expired"
            embed.description = "Unforunately, you could not afford to renew your role #{role_item.ui_name}, so it has been removed."
          end
        end
      end
    end

    # todo: check for expired tags
    # todo: check for expired commands
  end

  ###########################
  ##   STANDARD COMMANDS   ##
  ###########################
  # set the user's timezone
  SETTIMEZONE_COMMAND_NAME = "settimezone"
  SETTIMEZONE_DESCRIPTION = "Set your timezone.\nSee https://en.wikipedia.org/wiki/List_of_tz_database_time_zones for a list of valid values."
  SETTIMEZONE_ARGS = [["timezone_name", String]]
  SETTIMEZONE_REQ_COUNT = 1
  command :settimezone do |event, *args|
    # parse args
    opt_defaults = []
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      SETTIMEZONE_COMMAND_NAME,
      SETTIMEZONE_DESCRIPTION,
      SETTIMEZONE_ARGS,
      SETTIMEZONE_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil?

    timezone_name =  parsed_args["timezone_name"]
    if Bot::Timezone::SetUserTimezone(event.user.id, timezone_name)
      event.respond "Timezone set to #{Bot::Timezone::GetUserTimezone(event.user.id)}"
    else
      event.respond "Timezone not recognized \"#{timezone_name}\""
    end
  end

  # get the name of user's configured timezone
  command :gettimezone do |event|
    event.respond "Your current timezone is \"#{Bot::Timezone::GetUserTimezone(event.user.id)}\""
  end

  # get daily amount
  command :checkin do |event|
    user = DiscordUser.new(event.user.id)

    # determine if the user can checkin
    can_checkin = false
    last_timestamp = USER_CHECKIN_TIME[user_id: user.id]
    if last_timestamp != nil
      last_timestamp = last_timestamp[:checkin_timestamp]
      
      last_datetime = Bot::Timezone::GetTimestampInUserLocal(user.id, last_timestamp)
      today_datetime = Bot::Timezone::GetUserToday(user.id)
      can_checkin = last_datetime < today_datetime
    else
      can_checkin = true
    end

    # clean up for good measure since this will one of be the most performed action
    # note: calling this has no impact on the results of checkin
    Bot::Bank::CleanAccount(user.id)

    # checkin if they can do that today
    checkin_value = GetUserCheckinValue(user.id)
    if can_checkin
      Bot::Bank::Deposit(user.id, checkin_value)
      if last_timestamp == nil
        USER_CHECKIN_TIME << { user_id: user.id, checkin_timestamp: Time.now.to_i }
      else
        last_timestamp = USER_CHECKIN_TIME.where(user_id: user.id)
        last_timestamp.update(checkin_timestamp: Time.now.to_i)
      end
    end

     # Sends embed containing user bank profile
    event.send_embed do |embed|
      embed.author = {
          name: STRING_BANK_NAME,
          icon_url: IMAGE_BANK
      }

      embed.thumbnail = {url: user.avatar_url}
      embed.footer = {text: "Use +checkin once a day to earn #{checkin_value} Starbucks"}
      embed.color = COLOR_EMBED

      title = ""
      if user.nickname?
        title = " #{user.nickname} (#{user.full_username}) "
      else
        title = " #{user.full_username} "
      end
      embed.title = title

      # row: checkin won if could checkin
      if can_checkin
        embed.add_field(
          name: 'Checked in for',
          value: "#{checkin_value} Starbucks",
          inline: false
        )
      end

      # row: networth and next checkin time
      embed.add_field(
          name: 'Networth',
          value: "#{Bot::Bank::GetBalance(user.id)} Starbucks",
          inline: true
      )

      embed.add_field(
        name: "Time Until Next Check-in",
        value: GetTimeUntilNextCheckinString(user.id),
        inline: true
      )
    end
  end

  # display balances
  PROFILE_COMMAND_NAME = "profile"
  PROFILE_DESCRIPTION = "See your economic stats."
  PROFILE_ARGS = [["user", DiscordUser]]
  PROFILE_REQ_COUNT = 0
  command :profile do |event, *args|
    # parse args
    opt_defaults = [event.user.id]
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      PROFILE_COMMAND_NAME,
      PROFILE_DESCRIPTION,
      PROFILE_ARGS,
      PROFILE_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil? 

    # clean before showing profile
    user = parsed_args["user"]
    Bot::Bank::CleanAccount(user.id)

    # Sends embed containing user bank profile
    event.send_embed do |embed|
      embed.author = {
          name: STRING_BANK_NAME,
          icon_url: IMAGE_BANK
      }

      embed.thumbnail = {url: user.avatar_url}
      embed.footer = {text: "Use +checkin once a day to earn #{GetUserCheckinValue(user.id)} Starbucks"}
      embed.color = COLOR_EMBED

      title = ""
      if user.nickname?
        title = " #{user.nickname} (#{user.full_username}) "
      else
        title = " #{user.full_username} "
      end
      embed.title = title

      # ROW 1: Balances
      embed.add_field(
          name: 'Networth',
          value: "#{Bot::Bank::GetBalance(user.id)} Starbucks",
          inline: true
      )

      embed.add_field(
        name: 'At Risk',
        value: "#{Bot::Bank::GetAtRiskBalance(user.id)} Starbucks",
        inline: true
      )

      perma_balance = Bot::Bank::GetPermaBalance(user.id)
      if perma_balance < 0
        embed.add_field(
          name: "Outstanding Fines",
          value: "#{-perma_balance} Starbucks",
          inline: true
        )
      else
        embed.add_field(
          name: "Non-Expiring",
          value: "#{perma_balance} Starbucks",
          inline: true
        )
      end

      # ROW 2: Time until next checkin
      embed.add_field(
        name: "Time Until Next Check-in",
        value: GetTimeUntilNextCheckinString(user.id),
        inline: false
      )

      # ROW 3: TODO: Roles, Tags, Commands
    end
  end

  # display leaderboard
  # TODO: bug, results may differ from profile reporting
  RICHEST_COUNT = 10
  command :richest do |event|
    # note: timestamp filtering is a rough estimate based on the server's
    # timezone as it would be prohibitively expensive to clean up all entries
    # for all users prior to the query

    # compute when the last monday as a Unix timestmap
    past_monday = Date.today
    wwday = past_monday.cwday - 1
    past_monday = past_monday - wwday

    # compute last timestamp and query for entries that meet this requirement
    last_valid_timestamp = (past_monday - (Bot::Bank::MAX_BALANCE_AGE_DAYS + 1)).to_time.to_i
    sql =
      "SELECT user_id, SUM(amount) networth\n" +
      "FROM\n" + 
      "(\n" +
      "  SELECT user_id, amount FROM econ_user_balances\n" +
      "  WHERE timestamp >= #{last_valid_timestamp}\n" +
      "  UNION ALL\n" +
      "  SELECT user_id, amount FROM econ_user_perma_balances\n" +
      ") s\n" +
      "GROUP BY user_id\n" +
      "ORDER BY networth DESC\n" +
      "LIMIT #{RICHEST_COUNT};"

    richest = DB[sql]
    if richest == nil || richest.first == nil
      event.respond "No one appears to have money! Please give the devs a ring!!"
      break
    end

    top_user_stats = richest.all
    event.send_embed do |embed|
      embed.author = {
          name: "#{STRING_BANK_NAME}: Top 10",
          icon_url: IMAGE_BANK
      }
      embed.thumbnail = {url: IMAGE_RICHEST}
      embed.color = COLOR_EMBED
      embed.footer = {text: "Disclaimer: results may differ slightly from profile."}

      # add top ten uses
      top_names = ""
      top_networths = ""
      (0...top_user_stats.count).each do |n|
        user_stats = top_user_stats[n] 
        user_id = user_stats[:user_id]
        user = DiscordUser.new(user_id)
        networth = user_stats[:networth]

        if user.nickname?
          top_names += "#{n + 1}: #{user.nickname} (#{user.full_username})\n"
        else
          top_names += "#{n + 1}: #{user.full_username}\n"
        end

        top_networths += "#{networth} Starbucks\n"
      end

      embed.add_field(
            name: "Richest",
            value: top_names,
            inline: true
      )

      embed.add_field(
            name: "Networth",
            value: top_networths,
            inline: true
      )
    end
  end

  # transfer money to another account
  TRANSFERMONEY_COMMAND_NAME = "transfermoney"
  TRANSFERMONEY_DESCRIPTION = "Transfer funds to the specified user."
  TRANSFERMONEY_ARGS = [["to_user", DiscordUser], ["amount", Integer]]
  TRANSFERMONEY_REQ_COUNT = 2
  command :transfermoney do |event, *args|
    opt_defaults = []
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      TRANSFERMONEY_COMMAND_NAME,
      TRANSFERMONEY_DESCRIPTION,
      TRANSFERMONEY_ARGS,
      TRANSFERMONEY_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil?  

    from_user_id = event.user.id
    to_user_id = parsed_args["to_user"].id
    amount = parsed_args["amount"]
    if amount <= 0
      event.respond "You can't transfer negative funds!"
      break
    end

    # clean from_user's entries before transfer
    Bot::Bank::CleanAccount(from_user_id)

    # transfer funds
    if Bot::Bank::Withdraw(from_user_id, amount)
      Bot::Bank::Deposit(to_user_id, amount)
      event.respond "#{parsed_args["to_user"].mention}, #{event.user.username} has transfered #{amount} Starbucks to your account!"
    else
      event.respond "You have insufficient funds to transfer that much!"
    end
  end

  # rent a new role
  RENTAROLE_COMMAND_NAME = "rentarole"
  RENTAROLE_DESCRIPTION = "Rent the specified role."
  RENTAROLE_ARGS = [["role", String]]
  RENTAROLE_REQ_COUNT = 1
  command :rentarole do |event, *args|
    opt_defaults = []
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      RENTAROLE_COMMAND_NAME,
      RENTAROLE_DESCRIPTION,
      RENTAROLE_ARGS,
      RENTAROLE_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil?  

    Bot::Bank::CleanAccount(event.user.id)

    # Check to see if the user is already renting a role.
    rented_role = GetUserRentedRoleItem(event.user.id)
    if rented_role != nil
      event.respond "You already have a rented role!"
      break
    end

    # parse the user's input
    role_item_id = nil
    role_id = nil
    required_role_id = nil
    role_name = parsed_args["role"]
    case role_name.downcase
    when "orange", "obsolete_orange"
      role_item_id = Bot::Inventory::GetItemID('role_color_obsolete_orange')
      role_id = OBSOLETE_ORANGE_ROLE_ID
    when "blue", "breathtaking_blue"
      role_item_id = Bot::Inventory::GetItemID('role_color_breathtaking_blue')
      role_id = BREATHTAKING_BLUE_ROLE_ID
    when "red", "retro_red"
      role_item_id = Bot::Inventory::GetItemID('role_color_retro_red')
      role_id = RETRO_RED_ROLE_ID
    when "lavendar", "lullaby_lavendar", "purple"
      role_item_id = Bot::Inventory::GetItemID('role_color_lullaby_lavender')
      role_id = LULLABY_LAVENDER_ROLE_ID
    when "white", "white_white"
      role_item_id = Bot::Inventory::GetItemID('role_color_whitey_white')
      role_id = WHITEY_WHITE_ROLE_ID
    when "magenta", "marvelous_magenta"
      role_item_id = Bot::Inventory::GetItemID('role_color_marvelous_magenta')
      role_id = MARVELOUS_MAGENTA_ROLE_ID
    when "yellow", "shallow_yellow"
      role_item_id = Bot::Inventory::GetItemID('role_color_shallow_yellow')
      role_id = SHALLOW_YELLOW_ROLE_ID
    when "citizen", "override_citizen"
      role_item_id = Bot::Inventory::GetItemID('role_override_citizen')
      role_id = OVERRIDE_MEWMAN_CITIZEN_ROLE_ID
      required_role_id = MEWMAN_CITIZEN_ROLE_ID
    when "squire", "override_squire"
      role_item_id = Bot::Inventory::GetItemID('role_override_squire')
      role_id = OVERRIDE_MEWMAN_SQUIRE_ROLE_ID
      required_role_id = MEWMAN_SQUIRE_ROLE_ID
    when "knight", "override_knight"
      role_item_id = Bot::Inventory::GetItemID('role_override_knight')
      role_id = OVERRIDE_MEWMAN_KNIGHT_ROLE_ID
      required_role_id = MEWMAN_KNIGHT_ROLE_ID
    when "noble", "override_noble"
      role_item_id = Bot::Inventory::GetItemID('role_override_noble')
      role_id = OVERRIDE_MEWMAN_NOBLE_ROLE_ID
      required_role_id = MEWMAN_NOBLE_ROLE_ID
    when "monarch", "override_monarch"
      role_item_id = Bot::Inventory::GetItemID('role_override_noble')
      role_id = OVERRIDE_MEWMAN_MONARCH_ROLE_ID
      required_role_id = MEWMAN_MONARCH_ROLE_ID
    else 
      event.respond "Sorry, I couldn't find that role."
      break
    end

    # ensure the user meets the requiremetns
    user = DiscordUser.new(event.user.id)
    if required_role_id != nil && not(user.role?(required_role_id))
      event.respond "Sorry, you do not meet the level requirements for that override."
      break
    end

    # attempt to buy role
    role_cost = Bot::Inventory::GetItemValueFromID(role_item_id)
    if not Bot::Bank::Withdraw(user.id, role_cost)
      event.respond "Sorry, you can't afford that role."
      break
    end

    # compute expiration date
    now_datetime = Time.now.to_datetime

    # store in inventory
    Bot::Inventory::AddItem(user.id, role_item_id)

    # assign role and respond
    user.user.add_role(role_id)
    role_ui_name = Bot::Inventory::GetItemUINameFromID(role_item_id)
    event.respond "#{user.mention} you now have the #{role_ui_name} role!"
  end

  # remove rented role
  command :unrentarole do |event, *args|
  	Bot::Bank::CleanAccount(event.user.id)
    
    # check if the user is currently renting a role
    rented_role = GetUserRentedRoleItem(event.user.id)
    if rented_role == nil
      event.respond "You aren't currently renting a role!"
      break
    end

    role_id = GetRoleForItemID(rented_role.item_id)
    user = DiscordUser.new(event.user.id)
    if user.role?(role_id)
      user.user.remove_role(role_id)
    end

    Bot::Inventory::RemoveItem(rented_role.entry_id)
    event.respond "#{user.mention}, you no longer have the role #{rented_role.ui_name}!"
  end

  # custom tag management
  command :tag do |event, *args|
  	Bot::Bank::CleanAccount(event.user.id)
    
    puts "tag"
  	#add
  	#delete
  	#edit
  end

  # custom command mangement
  command :myconn do |event, *args|
  	Bot::Bank::CleanAccount(event.user.id)
    
    puts "myconn"
  	#set
  	#delete
  	#edit
  end

  ############################
  ##   MODERATOR COMMANDS   ##
  ############################
  FINE_COMMAND_NAME = "fine"
  FINE_DESCRIPTION = "Fine a user for inappropriate behavior."
  FINE_ARGS = [["user", DiscordUser], ["fine_size", String]]
  FINE_REQ_COUNT = 2
  command :fine do |event, *args|
    break unless (Convenience.IsUserDev(event.user.id) ||
                  event.user.role?(MODERATOR_ROLE_ID) ||
                  event.user.role?(HEAD_CREATOR_ROLE_ID))

    opt_defaults = []
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      FINE_COMMAND_NAME,
      FINE_DESCRIPTION,
      FINE_ARGS,
      FINE_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil?  

    user_id = parsed_args["user"].id
    user_mention = parsed_args["user"].mention
    severity = parsed_args["fine_size"]

    entry_id = "fine_#{severity}"
    fine_size = Bot::Bank::AppraiseItem(entry_id)
    orig_fine_size = fine_size
    if fine_size == nil
      event.respond "Invalid fine size specified (small, medium, large)."
      break
    end

    # clean before proceeding
    Bot::Bank::CleanAccount(user_id)

    # deduct fine from bank account balance
    balance = Bot::Bank::GetBalance(user_id)
    withdraw_amount = [fine_size, balance].min
    if withdraw_amount > 0
      Bot::Bank::Withdraw(user_id, withdraw_amount)
      fine_size -= withdraw_amount
    end

    # deposit rest as negative perma currency
    Bot::Bank::DepositPerma(user_id, -fine_size)

    mod_mention = DiscordUser.new(event.user.id).mention
    event.respond "#{user_mention} has been fined #{orig_fine_size} by #{mod_mention}"
  end

  ############################
  ##   DEVELOPER COMMANDS   ##
  ############################

  # Takes user's entire (positive) balance, displays gif, devs only
  SHUTUPANDTAKEMYMONEY_COMMAND_NAME = "shutupandtakemymoney"
  SHUTUPANDTAKEMYMONEY_DESCRIPTION = "Clear out your or another user's balance."
  SHUTUPANDTAKEMYMONEY_ARGS = [["user", DiscordUser]]
  SHUTUPANDTAKEMYMONEY_REQ_COUNT = 0
  command :shutupandtakemymoney do |event, *args|
    break unless Convenience::IsUserDev(event.user.id)

    opt_defaults = [event.user.id]
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      SHUTUPANDTAKEMYMONEY_COMMAND_NAME,
      SHUTUPANDTAKEMYMONEY_DESCRIPTION,
      SHUTUPANDTAKEMYMONEY_ARGS,
      SHUTUPANDTAKEMYMONEY_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil?  

    # no need to clean because we're going to clear all of their balance
    user_id = parsed_args["user"].id
    user_mention = parsed_args["user"].mention
    if Bot::Bank::GetBalance(user_id) <= 0
      event.respond "Sorry, you're already broke!"
      next # bail out, this fool broke
    end

  	# completely clear your balances
    Bot::Bank::USER_BALANCES.where{Sequel.&({user_id: user_id}, (amount > 0))}.delete
  	event.respond "#{user_mention} has lost all funds!\nhttps://media1.tenor.com/images/25489503d3a63aa7afbc0217eba128d3/tenor.gif?itemid=8581127"
  end

  # Clear all fines and balances.
  CLEARBALANCES_COMMAND_NAME = "clearbalances"
  CLEARBALANCES_DESCRIPTION = "Clear out your or another user's balance and fines."
  CLEARBALANCES_ARGS = [["user", DiscordUser]]
  CLEARBALANCES_REQ_COUNT = 0
  command :clearbalances do |event, *args|
    break unless Convenience::IsUserDev(event.user.id)

    opt_defaults = [event.user.id]
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      CLEARBALANCES_COMMAND_NAME,
      CLEARBALANCES_DESCRIPTION,
      CLEARBALANCES_ARGS,
      CLEARBALANCES_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil?  

    # no need to clean because we're going to clear all of their balance
    user_id = parsed_args["user"].id
    user_mention = parsed_args["user"].mention

    # completely clear your balances
    Bot::Bank::USER_BALANCES.where(user_id: user_id).delete
    Bot::Bank::USER_PERMA_BALANCES.where(user_id: user_id).delete
    event.respond "#{user_mention} has had all fines and balances cleared"
  end

  # gives a specified amount of starbucks, devs only
  GIMME_COMMAND_NAME = "gimme"
  GIMME_DESCRIPTION = "Give Starbucks to self or specified user."
  GIMME_ARGS = [["amount", Integer], ["type", String], ["user", DiscordUser]]
  GIMME_REQ_COUNT = 1
  command :gimme do |event, *args|
    break unless Convenience::IsUserDev(event.user.id)

    opt_defaults = ["temp", event.user.id]
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      GIMME_COMMAND_NAME,
      GIMME_DESCRIPTION,
      GIMME_ARGS,
      GIMME_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil?  

    type = parsed_args["type"]
    amount = parsed_args["amount"]
    user_id = parsed_args["user"].id
    user_mention = parsed_args["user"].mention
    Bot::Bank::CleanAccount(user_id)

    if type.downcase == "perma"
      Bot::Bank::DepositPerma(user_id, amount)
    else
      Bot::Bank::Deposit(user_id, amount)
    end

    event.respond "#{user_mention} received #{amount} Starbucks"
  end

  # takes a specified amount of starbucks, devs only
  TAKEIT_COMMAND_NAME = "takeit"
  TAKEIT_DESCRIPTION = "Take Starbucks from self or specified user."
  TAKEIT_ARGS = [["amount", Integer], ["user", DiscordUser]]
  TAKEIT_REQ_COUNT = 1
  command :takeit do |event, *args|
    break unless Convenience::IsUserDev(event.user.id)

    opt_defaults = [event.user.id]
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      TAKEIT_COMMAND_NAME,
      TAKEIT_DESCRIPTION,
      TAKEIT_ARGS,
      TAKEIT_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil?  

    # attempt to withdraw
    amount = parsed_args["amount"]
    user_id = parsed_args["user"].id
    user_mention = parsed_args["user"].mention
    Bot::Bank::CleanAccount(user_id)
    if Bot::Bank::Withdraw(user_id, amount)
      event.respond "#{user_mention} lost #{amount} Starbucks"
    else
      event.respond "#{user_mention} does not have at least #{amount} Starbucks"
    end
  end

  # print out the user's debug profile
  DEBUGPROFILE_COMMAND_NAME = "debugprofile"
  DEBUGPROFILE_DESCRIPTION = "Display a debug table of the user's info."
  DEBUGPROFILE_ARGS = [["user", DiscordUser]]
  DEBUGPROFILE_REQ_COUNT = 0
  command :debugprofile do |event, *args|
    break unless Convenience::IsUserDev(event.user.id)

    opt_defaults = [event.user.id]
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      DEBUGPROFILE_COMMAND_NAME,
      DEBUGPROFILE_DESCRIPTION,
      DEBUGPROFILE_ARGS,
      DEBUGPROFILE_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil? 

    user = parsed_args["user"]
    Bot::Bank::CleanAccount(user.id)
      
    response = 
      "**User:** #{user.full_username}\n" +
      "**Networth:** #{Bot::Bank::GetBalance(user.id)} Starbucks" +
      "\n**Non-Expiring:** #{Bot::Bank::GetPermaBalance(user.id)} Starbucks" +
      "\n\n**Table of Temp Balances**"

    user_transactions = Bot::Bank::USER_BALANCES.where{Sequel.&({user_id: user.id}, (amount > 0))}.order(Sequel.asc(:timestamp)).all
    (0...user_transactions.count).each do |n|
      transaction = user_transactions[n]

      amount = transaction[:amount]
      timestamp = transaction[:timestamp]
      response += "\n#{amount} received on #{Bot::Timezone::GetTimestampInUserLocal(event.user.id, timestamp)}"
    end

    event.respond response
  end

  # get timestamp of last checkin in the caller's local timezone
  LASTCHECKIN_COMMAND_NAME = "lastcheckin"
  LASTCHECKIN_DESCRIPTION = "Get the timestamp for when the specified user last checked in."
  LASTCHECKIN_ARGS = [["user", DiscordUser]]
  LASTCHECKIN_REQ_COUNT = 0
  command :lastcheckin do |event, *args|
    break unless Convenience::IsUserDev(event.user.id)

    opt_defaults = [event.user.id]
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      LASTCHECKIN_COMMAND_NAME,
      LASTCHECKIN_DESCRIPTION,
      LASTCHECKIN_ARGS,
      LASTCHECKIN_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil?  

    last_timestamp = USER_CHECKIN_TIME[user_id: parsed_args["user"].id]
    break unless last_timestamp != nil

    last_timestamp = last_timestamp[:checkin_timestamp]
    event.respond "Last checked in #{Bot::Timezone::GetTimestampInUserLocal(event.user.id, last_timestamp)}"
  end

  # clear last checkin timestamp
  CLEARLASTCHECKIN_COMMAND_NAME = "clearlastcheckin"
  CLEARLASTCHECKIN_DESCRIPTION = "Clear out the last checkin time."
  CLEARLASTCHECKIN_ARGS = [["user", DiscordUser]]
  CLEARLASTCHECKIN_REQ_COUNT = 0
  command :clearlastcheckin do |event, *args|
    break unless Convenience::IsUserDev(event.user.id)

    opt_defaults = [event.user.id]
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      LASTCHECKIN_COMMAND_NAME,
      LASTCHECKIN_DESCRIPTION,
      LASTCHECKIN_ARGS,
      LASTCHECKIN_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil?  

    USER_CHECKIN_TIME.where(user_id: parsed_args["user"].id).delete
    event.respond "Last checkin time cleared for #{parsed_args["user"].full_username}"
  end

  ADDITEM_COMMAND_NAME = "additem"
  ADDITEM_DESCRIPTION = "Give the user the specified item."
  ADDITEM_ARGS = [["item", String], ["user", DiscordUser]]
  ADDITEM_REQ_COUNT = 1
  command :additem do |event, *args|
    break unless Convenience::IsUserDev(event.user.id)

    opt_defaults = [event.user.id]
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      ADDITEM_COMMAND_NAME,
      ADDITEM_DESCRIPTION,
      ADDITEM_ARGS,
      ADDITEM_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil?

    item_name = parsed_args["item"]
    if Bot::Inventory::AddItemByName(parsed_args["user"].id, item_name)
      event.respond "#{item_name} added!"
    else
      event.repond "Item '#{item_name}' not recognized."
    end
  end

  INVENTORY_COMMAND_NAME = "inventory"
  INVENTORY_DESCRIPTION = "Get the user's complete inventory."
  INVENTORY_ARGS = [["user", DiscordUser], ["item_type", Integer]]
  INVENTORY_REQ_COUNT = 0
  command :inventory do |event, *args|
    break unless Convenience::IsUserDev(event.user.id)

    opt_defaults = [event.user.id, -1]
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      INVENTORY_COMMAND_NAME,
      INVENTORY_DESCRIPTION,
      INVENTORY_ARGS,
      INVENTORY_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil?

    user = parsed_args["user"]
    item_type = parsed_args["item_type"]
    item_type = item_type > 0 ? item_type : nil
    
    items = Bot::Inventory::GetInventory(user.id, item_type)
    value = Bot::Inventory::GetInventoryValue(user.id)
    response = "#{user.full_username} inventory valued at #{value} Starbucks\n"
    items.each do |item|
      if item.expiration != nil
        days_to_expiration = (item.expiration - Time.now.to_i)/(24.0*60.0*60.0)
        response += "#{item.ui_name} expires in #{days_to_expiration} days\n"
      else
        response += "#{item.ui_name}\n"
      end
    end
    
    event.respond response
  end

  CLEARINVENTORY_COMMAND_NAME = "clearinventory"
  CLEARINVENTORY_DESCRIPTION = "Get the user's complete inventory."
  CLEARINVENTORY_ARGS = [["user", DiscordUser]]
  CLEARINVENTORY_REQ_COUNT = 0
  command :clearinventory do |event, *args|
    break unless Convenience::IsUserDev(event.user.id)

    opt_defaults = [event.user.id]
    parsed_args = Convenience::ParseArgsAndRespondIfInvalid(
      event,
      CLEARINVENTORY_COMMAND_NAME,
      CLEARINVENTORY_DESCRIPTION,
      CLEARINVENTORY_ARGS,
      CLEARINVENTORY_REQ_COUNT,
      opt_defaults,
      args)
    break unless not parsed_args.nil?

    user = parsed_args["user"]
    items = Bot::Inventory::GetInventory(user.id)
    items.each do |item|
      Bot::Inventory::RemoveItem(item.entry_id)
    end

    event.respond "#{user.full_username}'s inventory was cleared"
  end

  # econ dummy command, does nothing lazy cleanup devs only
  command :econdummy do |event|
    break unless Convenience::IsUserDev(event.user.id)

    Bot::Bank::CleanAccount(event.user.id)
    event.respond "Database cleaned for #{event.user.username}##{event.user.discriminator}"
  end
end