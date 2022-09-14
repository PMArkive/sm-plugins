#include <sourcemod>
#include <economy>
#include <tf2>
#include <tf2_stocks>
#include <morecolors>
#include <bit>
#include <animstate>
#include <savenames>

//TODO!!!!! urgent make a keyvalues to configure methods of giving credits

//#define DEBUG

#define QUERY_STR_MAX 1024

#define TF2_MAXPLAYERS 33

#define ECON_CON_PREFIX "[ECON] "
#define ECON_CHAT_PREFIX "{dodgerblue}[ECON]{default} "

#define ECON_SHOP_PRICE_STR_LEN 10
#define ECON_SHOP_CREDITS_STR_LEN 10

#define ECON_SHOP_ITEM_TITLE_LEN (6 + ECON_MAX_ITEM_NAME + 2 + 6 + ECON_MAX_ITEM_DESCRIPTION + 2 + 6 + 7 + ECON_SHOP_PRICE_STR_LEN + 2)
#define ECON_INV_ITEM_TITLE_LEN (6 + ECON_MAX_ITEM_NAME + 2 + 6 + ECON_MAX_ITEM_DESCRIPTION + 2)

#define ECON_SHOP_TITLE_LEN (4 + 6 + 9 + ECON_SHOP_CREDITS_STR_LEN + 2)
#define ECON_INV_TITLE_LEN (9 + 6 + 9 + ECON_SHOP_CREDITS_STR_LEN + 2)

enum struct ItemCategoryInfo
{
	int id;
	char name[ECON_MAX_ITEM_CATEGORY_NAME];
	ArrayList items;
	int parent_id;
	int parent_idx;
	ArrayList childs;
	Menu shop_menu;
}

enum struct ItemInfo
{
	int id;
	char name[ECON_MAX_ITEM_NAME];
	char desc[ECON_MAX_ITEM_DESCRIPTION];
	char classname[ECON_MAX_ITEM_CLASSNAME];
	StringMap settings;
	int price;
	int category;
	Menu shop_menu;
}

enum struct PlayerInventoryCategory
{
	Menu menu;
}

enum struct PlayerItemInfo
{
	int idx;
	int id;
}

enum struct ItemHandler
{
	bool equipable;
	PrivateForward handle_fwd;
	PrivateForward cache_fwd;
	PrivateForward conflict_fwd;
	PrivateForward menu_fwd;
	//PrivateForward preview_fwd;
	Handle plugin;
	char classname[ECON_MAX_ITEM_CLASSNAME];
	ArrayList items;
}

static StringMap item_id_cache_idx_map;
static ArrayList items;
static StringMap category_id_cache_idx_map;
static ArrayList categories;
static StringMap item_class_buckets;
static Menu shop_menu;

static Handle hud;

static int player_currency[TF2_MAXPLAYERS+1];
static ArrayList player_inventory[TF2_MAXPLAYERS+1];
static ArrayList player_inventory_equipped[TF2_MAXPLAYERS+1];
static StringMap player_inventory_categories[TF2_MAXPLAYERS+1];
static Menu player_inventory_menu[TF2_MAXPLAYERS+1];
static ArrayList player_purchase_queue[TF2_MAXPLAYERS+1];

static Handle player_currency_timer[TF2_MAXPLAYERS+1];

static bool playing_shop_music[TF2_MAXPLAYERS+1];
static int player_taunt_stage[TF2_MAXPLAYERS+1];

static ArrayList item_handlers;
static StringMap item_handlers_map;

static int current_menu_type;
static Menu current_menu;

static GlobalForward fwd_loaded;
static Database econ_db;
static bool items_loaded;

static void query_error(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null) {
		LogError("%s", error);
	}
}

static void transaction_error(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	LogError("%s", error);
}

static void add_category_to_player_inv_menu(int client, int child, const char[] child_name, int parent)
{
	ItemCategoryInfo catinfo;
	categories.GetArray(parent, catinfo, sizeof(ItemCategoryInfo));

	char str[10];
	pack_int_in_str(parent, str);

	PlayerInventoryCategory plrinvcat;
	if(!player_inventory_categories[client].GetArray(str, plrinvcat, sizeof(PlayerInventoryCategory))) {
		plrinvcat.menu = new Menu(menuhandler_inv_cat);

		char category_menu_title[15 + ECON_MAX_ITEM_CATEGORY_NAME];
		Format(category_menu_title, sizeof(category_menu_title), "Category: %s", catinfo.name);
		plrinvcat.menu.SetTitle(category_menu_title);

		plrinvcat.menu.ExitBackButton = true;

		plrinvcat.menu.AddItem(str, "", ITEMDRAW_IGNORE);

		if(catinfo.parent_idx == -1) {
			player_inventory_menu[client].AddItem(str, catinfo.name);
		} else {
			add_category_to_player_inv_menu(client, parent, catinfo.name, catinfo.parent_idx);
		}

		pack_int_in_str(parent, str);
		player_inventory_categories[client].SetArray(str, plrinvcat, sizeof(PlayerInventoryCategory));
	}

	pack_int_in_str(1, str, 0);
	pack_int_in_str(child, str, 4);
	plrinvcat.menu.AddItem(str, child_name);
}

static void add_item_to_player_inv_menu(int client, int id, int idx)
{
	ItemInfo info;
	items.GetArray(idx, info, sizeof(info));

	ItemCategoryInfo catinfo;
	categories.GetArray(info.category, catinfo, sizeof(ItemCategoryInfo));

	char str[15];
	pack_int_in_str(info.category, str);

	PlayerInventoryCategory plrinvcat;
	if(!player_inventory_categories[client].GetArray(str, plrinvcat, sizeof(PlayerInventoryCategory))) {
		plrinvcat.menu = new Menu(menuhandler_inv_cat);

		char category_menu_title[15 + ECON_MAX_ITEM_CATEGORY_NAME];
		Format(category_menu_title, sizeof(category_menu_title), "Category: %s", catinfo.name);
		plrinvcat.menu.SetTitle(category_menu_title);

		plrinvcat.menu.ExitBackButton = true;

		plrinvcat.menu.AddItem(str, "", ITEMDRAW_IGNORE);

		if(catinfo.parent_idx == -1) {
			player_inventory_menu[client].AddItem(str, catinfo.name);
		} else {
			add_category_to_player_inv_menu(client, info.category, catinfo.name, catinfo.parent_idx);
		}

		player_inventory_categories[client].SetArray(str, plrinvcat, sizeof(PlayerInventoryCategory));
	}

	pack_int_in_str(0, str, 0);
	pack_int_in_str(idx, str, 4);
	pack_int_in_str(id, str, 8);

	plrinvcat.menu.AddItem(str, info.name);
}

static void remove_category_from_player_inv_menu(int client, int idx)
{
	int parent_idx = categories.Get(idx, ItemCategoryInfo::parent_idx);

	char str[15];

	if(parent_idx == -1) {
		int len = player_inventory_menu[client].ItemCount;
		for(int i = 0; i < len; ++i) {
			player_inventory_menu[client].GetItem(i, str, sizeof(str));

			int menuidx = unpack_int_in_str(str);
			if(menuidx != idx) {
				continue;
			}

			player_inventory_menu[client].RemoveItem(i);
			break;
		}
	} else {
		pack_int_in_str(parent_idx, str);

		PlayerInventoryCategory plrinvcat;
		if(player_inventory_categories[client].GetArray(str, plrinvcat, sizeof(PlayerInventoryCategory))) {
			int len = plrinvcat.menu.ItemCount;
			for(int i = 1; i < len; ++i) {
				plrinvcat.menu.GetItem(i, str, sizeof(str));

				bool is_sub_cat = (unpack_int_in_str(str, 0) != 0);
				if(!is_sub_cat) {
					continue;
				}
			
				int menuidx = unpack_int_in_str(str, 4);
				if(menuidx != idx) {
					continue;
				}

				plrinvcat.menu.RemoveItem(i);
				break;
			}

			if(plrinvcat.menu.ItemCount < 2) {
				remove_category_from_player_inv_menu(client, parent_idx);

				delete plrinvcat.menu;

				pack_int_in_str(parent_idx, str);
				player_inventory_categories[client].Remove(str);
			}
		}
	}
}

static void remove_item_from_player_inv_menu(int client, int id, int idx)
{
	int category = items.Get(idx, ItemInfo::category);

	char str[15];
	pack_int_in_str(category, str);

	PlayerInventoryCategory plrinvcat;
	if(player_inventory_categories[client].GetArray(str, plrinvcat, sizeof(PlayerInventoryCategory))) {
		int len = plrinvcat.menu.ItemCount;
		for(int i = 1; i < len; ++i) {
			plrinvcat.menu.GetItem(i, str, sizeof(str));

			bool is_sub_cat = (unpack_int_in_str(str, 0) != 0);
			if(is_sub_cat) {
				continue;
			}
		
			int menuidx = unpack_int_in_str(str, 4);
			if(menuidx != idx) {
				continue;
			}

			int menuid = unpack_int_in_str(str, 8);
			if(menuid != id) {
				continue;
			}

			plrinvcat.menu.RemoveItem(i);
			break;
		}

		if(plrinvcat.menu.ItemCount < 2) {
			remove_category_from_player_inv_menu(client, category);

			delete plrinvcat.menu;

			pack_int_in_str(category, str);
			player_inventory_categories[client].Remove(str);
		}
	}
}

static void remove_items_from_player_inv(int client, int idx, bool from_db)
{
	if(from_db) {
		int item_id = cache_idx_to_item_id(idx);

		char query[QUERY_STR_MAX];
		econ_db.Format(query, QUERY_STR_MAX,
			"delete from player_inventory where " ...
			" accid=%i and item=%i " ...
			";"
			,GetSteamAccountID(client),
			item_id
		);
		econ_db.Query(query_error, query);
	}

	if(player_inventory[client] != null) {
		int i = -1;
		while((i = player_inventory[client].FindValue(idx, PlayerItemInfo::idx)) != -1) {
			int id = player_inventory[client].Get(i, PlayerItemInfo::id);

			remove_item_from_player_inv_menu(client, id, idx);

			player_inventory[client].Erase(i);
		}
	}

	if(player_inventory_equipped[client] != null) {
		ItemInfo info;

		int i = -1;
		while((i = player_inventory_equipped[client].FindValue(idx, PlayerItemInfo::idx)) != -1) {
			int id = player_inventory_equipped[client].Get(i, PlayerItemInfo::id);

			items.GetArray(idx, info, sizeof(ItemInfo));

			int hndlr_idx = -1;
			if(item_handlers_map.GetValue(info.classname, hndlr_idx)) {
				PrivateForward handle_fwd = item_handlers.Get(hndlr_idx, ItemHandler::handle_fwd);

				Call_StartForward(handle_fwd);
				Call_PushCell(client);
				Call_PushString(info.classname);
				Call_PushCell(idx);
				Call_PushCell(id);
				Call_PushCell(econ_item_remove);
				Call_Finish();

				Call_StartForward(handle_fwd);
				Call_PushCell(client);
				Call_PushString(info.classname);
				Call_PushCell(idx);
				Call_PushCell(id);
				Call_PushCell(econ_item_unequip);
				Call_Finish();
			}

			remove_item_from_player_inv_menu(client, id, idx);

			player_inventory_equipped[client].Erase(i);
		}
	}
}

static void query_player_inv_added(Database db, DBResultSet results, const char[] error, DataPack data)
{
	data.Reset();

	int client = GetClientOfUserId(data.ReadCell());
	if(client == 0) {
		delete data;
		return;
	}

	int idx = data.ReadCell();

	bool equipped = view_as<bool>(data.ReadCell());

	bool msg = view_as<bool>(data.ReadCell());

	delete data;

	int pq = player_purchase_queue[client].FindValue(idx);
	if(pq != -1) {
		player_purchase_queue[client].Erase(pq);
	}

	if(results == null) {
		LogError("%s", error);
		return;
	}

	int id = results.InsertId;

	if(msg && equipped) {
		CPrintToChat(client, ECON_CHAT_PREFIX ... "Your item was equipped. Use !inv to unequip it.");
	}

	if(equipped) {
		unequip_conflicts(client, idx);
	}

	player_item_loaded(client, idx, id, equipped);
}

static void add_item_to_player_inv(int client, int idx, bool msg = true)
{
	int item_id = cache_idx_to_item_id(idx);

	player_purchase_queue[client].Push(idx);

	ItemInfo info;
	items.GetArray(idx, info, sizeof(ItemInfo));

	bool equipped = false;

	int hndlr_idx = -1;
	if(item_handlers_map.GetValue(info.classname, hndlr_idx)) {
		equipped = item_handlers.Get(hndlr_idx, ItemHandler::equipable);
	}

	char query[QUERY_STR_MAX];
	econ_db.Format(query, QUERY_STR_MAX,
		"insert into player_inventory " ...
		" (accid,item,equipped) " ...
		" values " ...
		" (%i,%i,%i) " ...
		";"
		,GetSteamAccountID(client),item_id,equipped ? 1 : 0
	);
	DataPack data = new DataPack();
	data.WriteCell(GetClientUserId(client));
	data.WriteCell(idx);
	data.WriteCell(equipped);
	data.WriteCell(msg);
	econ_db.Query(query_player_inv_added, query, data);
}

static void modify_player_currency(int client, int amount)
{
#if defined DEBUG
	if(IsFakeClient(client)) {
		LogError("tried to modify BOT currency");
		return;
	}
#endif

	int team = GetClientTeam(client);
	int r = (team == 2 ? 255 : 0);
	int b = (team == 3 ? 255 : 0);

	SetHudTextParams(0.1, 0.20, 1.0, r, 0, b, 255);
	if(amount >= 0) {
		ShowSyncHudText(client, hud, "+%i Credits", amount);
	} else {
		ShowSyncHudText(client, hud, "%i Credits", amount);
	}

	player_currency[client] += amount;

	if(player_currency[client] < 0) {
		player_currency[client] = 0;
	}

	if(econ_db != null) {
		char query[QUERY_STR_MAX];
		econ_db.Format(query, QUERY_STR_MAX,
			"replace player_currency set " ...
			" accid=%i, amount=%i " ...
			";"
			,GetSteamAccountID(client),
			player_currency[client]
		);
		econ_db.Query(query_error, query);
	}
}

static void player_death(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if(!IsFakeClient(victim)) {
		handle_player_inventory(victim, econ_item_remove);
	} else {
	#if !defined DEBUG
		return;
	#endif
	}

	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if(victim == attacker) {
		return;
	}

	int death_flags = event.GetInt("death_flags");
	if(!!(death_flags & TF_DEATHFLAG_DEADRINGER)) {
		return;
	}

	if(attacker != 0 && !IsFakeClient(attacker)) {
		static const int attacker_currency = 2;
		modify_player_currency(attacker, attacker_currency);
	}

	int assister = GetClientOfUserId(event.GetInt("assister"));
	if(assister != 0 && !IsFakeClient(assister)) {
		static const int assister_currency = 1;
		modify_player_currency(assister, assister_currency);
	}
}

static void object_destroyed(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if(victim == 0) {
		return;
	}

#if !defined DEBUG
	if(IsFakeClient(victim)) {
		return;
	}
#endif
}

static void query_rank(Database db, DBResultSet results, const char[] error, DataPack data)
{
	data.Reset();

	Menu rankmenu = data.ReadCell();

	int client = GetClientOfUserId(data.ReadCell());

	delete data;

	if(client == 0) {
		return;
	}

	if(results == null) {
		LogError("%s", error);
		return;
	}

	for(int i = 0; i < results.RowCount; ++i) {
		if(!results.FetchRow()) {
			LogError("fetch failed");
			return;
		}

		int accid = results.FetchInt(0);
		int amount = results.FetchInt(1);

		char str[10];
		pack_int_in_str(accid, str, 0);
		pack_int_in_str(amount, str, 4);

		rankmenu.AddItem(str, "", ITEMDRAW_DISABLED);
	}

	rankmenu.Display(client, MENU_TIME_FOREVER);
}

static int get_client_of_accid(int accid)
{
	for(int i = 1; i <= MaxClients; ++i) {
		if(IsClientInGame(i) && !IsFakeClient(i)) {
			if(GetSteamAccountID(i) == accid) {
				return i;
			}
		}
	}
	return 0;
}

static int menuhandler_rank(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action) {
		case MenuAction_DisplayItem: {
			char str[10];
			menu.GetItem(param2, str, sizeof(str));

			int accid = unpack_int_in_str(str, 0);
			int amount = unpack_int_in_str(str, 4);

			char display[MAX_NAME_LENGTH + 10];

			int target = get_client_of_accid(accid);
			if(target != 0) {
				Format(display, sizeof(display), "%N: %i", target, player_currency[target]);
			} else {
				char name[MAX_NAME_LENGTH];
				sn_get(accid, name, MAX_NAME_LENGTH);
				Format(display, sizeof(display), "%s: %i", name, amount);
			}

			return RedrawMenuItem(display);
		}
		case MenuAction_End: {
			delete menu;
		}
	}

	return 0;
}

static Action sm_shoprank(int client, int args)
{
	if(econ_db == null) {
		return Plugin_Handled;
	}

	Menu rankmenu = new Menu(menuhandler_rank, MENU_ACTIONS_DEFAULT|MenuAction_DisplayItem);

	char query[QUERY_STR_MAX];
	econ_db.Format(query, QUERY_STR_MAX, "select accid,amount from player_currency where amount > 0 order by amount desc limit 100");
	DataPack data = new DataPack();
	data.WriteCell(rankmenu);
	data.WriteCell(GetClientUserId(client));
	econ_db.Query(query_rank, query, data);

	return Plugin_Handled;
}

public void OnPluginStart()
{
	fwd_loaded = new GlobalForward("econ_loaded", ET_Ignore);

	if(SQL_CheckConfig("economy")) {
		Database.Connect(database_connect, "economy");
	}

	hud = CreateHudSynchronizer();

	HookEvent("player_death", player_death);
	HookEvent("object_destroyed", object_destroyed);

	HookEvent("player_spawn", player_spawn);
	HookEvent("post_inventory_application", post_inventory_application);

	RegConsoleCmd("sm_shop", sm_shop);
	RegConsoleCmd("sm_store", sm_shop);

	RegConsoleCmd("sm_inventory", sm_inventory);
	RegConsoleCmd("sm_inv", sm_inventory);

	RegConsoleCmd("sm_shoprank", sm_shoprank);
	RegConsoleCmd("sm_rankshop", sm_shoprank);

	RegAdminCmd("sm_mcurr", sm_mcurr, ADMFLAG_ROOT);

	RegAdminCmd("sm_givei", sm_givei, ADMFLAG_ROOT);
	RegAdminCmd("sm_remi", sm_remi, ADMFLAG_ROOT);

	for(int i = 1; i <= MaxClients; ++i) {
		if(IsClientInGame(i)) {
			OnClientPutInServer(i);
		}
		if(IsClientAuthorized(i)) {
			OnClientAuthorized(i, "");
		}
	}
}

static Action sm_remi(int client, int args)
{
	if(args != 2) {
		ReplyToCommand(client, "[SM] Usage: sm_remi <filter> <idx>");
		return Plugin_Handled;
	}

	char filter[64];
	GetCmdArg(1, filter, sizeof(filter));

	int item_id = GetCmdArgInt(2);
	int idx = -1;
	if(item_id != -1) {
		idx = item_id_to_cache_idx(item_id);
		if(idx == -1) {
			ReplyToCommand(client, "[SM] Invalid item id");
			return Plugin_Handled;
		}
	}

	char name[MAX_TARGET_LENGTH];
	bool isml = false;
	int targets[MAXPLAYERS];
	int count = ProcessTargetString(filter, client, targets, MAXPLAYERS, COMMAND_FILTER_ALIVE, name, sizeof(name), isml);
	if(count == 0) {
		ReplyToTargetError(client, count);
		return Plugin_Handled;
	}

	for(int i = 0; i < count; ++i) {
		int target = targets[i];

		if(item_id == -1) {
			int len = items.Length;
			for(int j = 0; j < len; ++j) {
				if(!player_has_item(target, j)) {
					continue;
				}

				remove_items_from_player_inv(target, j, true);
			}
		} else {
			if(!player_has_item(target, idx)) {
				continue;
			}

			remove_items_from_player_inv(target, idx, true);
		}
	}

	return Plugin_Handled;
}

static Action sm_givei(int client, int args)
{
	if(args != 2) {
		ReplyToCommand(client, "[SM] Usage: sm_givei <filter> <idx>");
		return Plugin_Handled;
	}

	char filter[64];
	GetCmdArg(1, filter, sizeof(filter));

	int item_id = GetCmdArgInt(2);
	int idx = -1;
	if(item_id != -1) {
		idx = item_id_to_cache_idx(item_id);
		if(idx == -1) {
			ReplyToCommand(client, "[SM] Invalid item id");
			return Plugin_Handled;
		}
	}

	char name[MAX_TARGET_LENGTH];
	bool isml = false;
	int targets[MAXPLAYERS];
	int count = ProcessTargetString(filter, client, targets, MAXPLAYERS, COMMAND_FILTER_ALIVE, name, sizeof(name), isml);
	if(count == 0) {
		ReplyToTargetError(client, count);
		return Plugin_Handled;
	}

	for(int i = 0; i < count; ++i) {
		int target = targets[i];

		if(item_id == -1) {
			int len = items.Length;
			for(int j = 0; j < len; ++j) {
				if(player_has_item(target, j)) {
					continue;
				}

				add_item_to_player_inv(target, j, false);
			}
		} else {
			if(player_has_item(target, idx)) {
				continue;
			}

			add_item_to_player_inv(target, idx);
		}
	}

	return Plugin_Handled;
}

static Action sm_mcurr(int client, int args)
{
	if(args != 2) {
		ReplyToCommand(client, "[SM] Usage: sm_mcurr <filter> <value>");
		return Plugin_Handled;
	}

	char filter[64];
	GetCmdArg(1, filter, sizeof(filter));

	int amount = GetCmdArgInt(2);

	char name[MAX_TARGET_LENGTH];
	bool isml = false;
	int targets[MAXPLAYERS];
	int count = ProcessTargetString(filter, client, targets, MAXPLAYERS, COMMAND_FILTER_ALIVE, name, sizeof(name), isml);
	if(count == 0) {
		ReplyToTargetError(client, count);
		return Plugin_Handled;
	}

	for(int i = 0; i < count; ++i) {
		int target = targets[i];

		modify_player_currency(target, amount);
	}

	return Plugin_Handled;
}

public void OnAllPluginsLoaded()
{
	
}

public void OnNotifyPluginUnloaded(Handle plugin)
{
	int hndlr_idx = item_handlers.FindValue(plugin, ItemHandler::plugin);
	if(hndlr_idx != -1) {
		ItemHandler hndlr;
		item_handlers.GetArray(hndlr_idx, hndlr, sizeof(ItemHandler));

		int len = hndlr.items.Length;
		for(int i = 0; i < len; ++i) {
			int idx = hndlr.items.Get(i);

			for(int j = 1; j <= MaxClients; ++j) {
				if(IsClientInGame(j) && !IsFakeClient(j)) {
					remove_items_from_player_inv(j, idx, false);
				}
			}
		}

		delete hndlr.handle_fwd;
		delete hndlr.cache_fwd;
		delete hndlr.conflict_fwd;
		delete hndlr.menu_fwd;
		//delete hndlr.preview_fwd;
		delete hndlr.items;

		item_handlers_map.Remove(hndlr.classname);
		item_handlers.Erase(hndlr_idx);
	}
}

static void unequip_conflicts(int client, int idx)
{
	ItemInfo info;
	items.GetArray(idx, info, sizeof(ItemInfo));

	int hndlr_idx = -1;
	if(item_handlers_map.GetValue(info.classname, hndlr_idx)) {
		PrivateForward conflict_fwd = item_handlers.Get(hndlr_idx, ItemHandler::conflict_fwd);

		ItemInfo other_info;
		PlayerItemInfo plrinfo;

		char query[QUERY_STR_MAX];

		for(int i = 0; i < player_inventory_equipped[client].Length;) {
			player_inventory_equipped[client].GetArray(i, plrinfo, sizeof(PlayerItemInfo));

			items.GetArray(plrinfo.idx, other_info, sizeof(ItemInfo));

			Call_StartForward(conflict_fwd);
			Call_PushString(info.classname);
			Call_PushCell(idx);
			Call_PushString(other_info.classname);
			Call_PushCell(plrinfo.idx);
			Action conflict = Plugin_Continue;
			Call_Finish(conflict);

			if(conflict >= Plugin_Changed) {
				econ_db.Format(query, QUERY_STR_MAX,
					"update player_inventory set " ...
					" equipped=%i " ...
					" where " ...
					" id=%i " ...
					";"
					,0,
					plrinfo.id
				);
				econ_db.Query(query_error, query);

				handle_player_item(client, plrinfo.idx, plrinfo.id, econ_item_remove);
				handle_player_item(client, plrinfo.idx, plrinfo.id, econ_item_unequip);
			} else {
				++i;
			}
		}
	}
}

static void handle_player_item(int client, int idx, int id, econ_item_action action)
{
	if(action == econ_item_equip) {
		unequip_conflicts(client, idx);

		int pos = player_inventory[client].FindValue(id, PlayerItemInfo::id);
		if(pos != -1) {
			player_inventory[client].Erase(pos);
		}

		PlayerItemInfo info;
		info.idx = idx;
		info.id = id;
		player_inventory_equipped[client].PushArray(info, sizeof(PlayerItemInfo));
	}

	ItemInfo info;
	items.GetArray(idx, info, sizeof(ItemInfo));

	int hndlr_idx = -1;
	if(item_handlers_map.GetValue(info.classname, hndlr_idx)) {
		PrivateForward handle_fwd = item_handlers.Get(hndlr_idx, ItemHandler::handle_fwd);

		Call_StartForward(handle_fwd);
		Call_PushCell(client);
		Call_PushString(info.classname);
		Call_PushCell(idx);
		Call_PushCell(id);
		Call_PushCell(action);
		Call_Finish();
	}

	if(action == econ_item_unequip) {
		int pos = player_inventory_equipped[client].FindValue(id, PlayerItemInfo::id);
		if(pos != -1) {
			player_inventory_equipped[client].Erase(pos);

			PlayerItemInfo plrinfo;
			plrinfo.idx = idx;
			plrinfo.id = id;
			player_inventory[client].PushArray(plrinfo, sizeof(PlayerItemInfo));
		}
	}
}

static void handle_player_inventory_impl(int client, ArrayList &arr, int idx, econ_item_action action)
{
	if(arr != null) {
		ItemInfo info;
		PlayerItemInfo plrinfo;

		for(int j = 0; j < arr.Length; ++j) {
			arr.GetArray(j, plrinfo, sizeof(PlayerItemInfo));

			if(idx != -1) {
				if(plrinfo.idx != idx) {
					++j;
					continue;
				}
			}

			items.GetArray(plrinfo.idx, info, sizeof(ItemInfo));

			int hndlr_idx = -1;
			if(item_handlers_map.GetValue(info.classname, hndlr_idx)) {
				PrivateForward handle_fwd = item_handlers.Get(hndlr_idx, ItemHandler::handle_fwd);

				Call_StartForward(handle_fwd);
				Call_PushCell(client);
				Call_PushString(info.classname);
				Call_PushCell(plrinfo.idx);
				Call_PushCell(plrinfo.id);
				Call_PushCell(action);
				Call_Finish();
			}
		}
	}
}

static void handle_player_inventory(int client, econ_item_action action)
{
	handle_player_inventory_impl(client, player_inventory_equipped[client], -1, action);
}

public void OnPluginEnd()
{
	for(int i = 1; i <= MaxClients; ++i) {
		if(IsClientInGame(i) && !IsFakeClient(i)) {
			handle_player_inventory(i, econ_item_remove);
			handle_player_inventory(i, econ_item_unequip);
		}
	}
}

static void post_inventory_application_frame(int userid)
{
	int client = GetClientOfUserId(userid);
	if(client == 0) {
		return;
	}

	handle_player_inventory(client, econ_item_apply);
}

static void post_inventory_application(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	if(IsFakeClient(client)) {
		return;
	}

	RequestFrame(post_inventory_application_frame, userid);
}

static void player_spawn(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	if(IsFakeClient(client)) {
		return;
	}

	RequestFrame(post_inventory_application_frame, userid);
}

static void cache_player_inventory_late(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	for(int i = 0; i < numQueries; ++i) {
		int client = GetClientOfUserId(queryData[i]);
		if(client == 0) {
			continue;
		}

		init_player_vars(client);

		handle_result_set(results[i], cache_player_inventory, queryData[i]);
	}
}

static int native_econ_register_item_class(Handle plugin, int params)
{
	int length = 0;
	GetNativeStringLength(1, length);
	char[] classname = new char[++length];
	GetNativeString(1, classname, length);

	if(item_handlers_map.ContainsKey(classname)) {
		return ThrowNativeError(SP_ERROR_NATIVE, "classname %s already registered", classname);
	}

	bool equipable = GetNativeCell(2);

	ItemHandler hndlr;
	hndlr.equipable = equipable;
	hndlr.handle_fwd = new PrivateForward(ET_Ignore, Param_Cell, Param_String, Param_Cell, Param_Cell, Param_Cell);
	hndlr.cache_fwd = new PrivateForward(ET_Ignore, Param_String, Param_Cell, Param_Cell);
	hndlr.conflict_fwd = new PrivateForward(ET_Hook, Param_String, Param_Cell, Param_String, Param_Cell);
	hndlr.menu_fwd = new PrivateForward(ET_Ignore, Param_String, Param_Cell);
	//hndlr.preview_fwd = new PrivateForward(ET_Ignore, Param_Cell, Param_String, Param_Cell, Param_Cell);
	hndlr.plugin = plugin;
	strcopy(hndlr.classname, ECON_MAX_ITEM_CLASSNAME, classname);
	hndlr.items = new ArrayList();

	int hndlr_idx = item_handlers.PushArray(hndlr, sizeof(ItemHandler));

	item_handlers_map.SetValue(classname, hndlr_idx);

	if(items_loaded) {
		ArrayList bucket = null;
		if(item_class_buckets.GetValue(classname, bucket)) {
			int len = bucket.Length;
			for(int i = 0; i < len; ++i) {
				int idx = bucket.Get(i);

				hndlr.items.Push(idx);
			}
		}
	}

	Function func = GetFunctionByName(plugin, "econ_handle_item");
	if(func != INVALID_FUNCTION) {
		hndlr.handle_fwd.AddFunction(plugin, func);
	}

	func = GetFunctionByName(plugin, "econ_cache_item");
	if(func != INVALID_FUNCTION) {
		hndlr.cache_fwd.AddFunction(plugin, func);
	}

	func = GetFunctionByName(plugin, "econ_items_conflict");
	if(func != INVALID_FUNCTION) {
		hndlr.conflict_fwd.AddFunction(plugin, func);
	}

	func = GetFunctionByName(plugin, "econ_modify_menu");
	if(func != INVALID_FUNCTION) {
		hndlr.menu_fwd.AddFunction(plugin, func);
	}

	/*func = GetFunctionByName(plugin, "econ_item_preview");
	if(func != INVALID_FUNCTION) {
		hndlr.preview_fwd.AddFunction(plugin, func);
	}*/

	if(items_loaded) {
		func = GetFunctionByName(plugin, "econ_loaded");
		if(func != INVALID_FUNCTION) {
			Call_StartFunction(plugin, func);
			Call_Finish();
		}

		ArrayList bucket = null;
		if(item_class_buckets.GetValue(classname, bucket)) {
			func = GetFunctionByName(plugin, "econ_cache_item");
			if(func != INVALID_FUNCTION) {
				int len = bucket.Length;
				for(int i = 0; i < len; ++i) {
					int idx = bucket.Get(i);

					StringMap settings = items.Get(idx, ItemInfo::settings);

					Call_StartFunction(plugin, func);
					Call_PushString(classname);
					Call_PushCell(idx);
					Call_PushCell(settings);
					Call_Finish();
				}
			}

			char query[QUERY_STR_MAX];

			PlayerItemInfo plrinfo;

			ArrayList loaded_ids = new ArrayList();
			Transaction tr = new Transaction();

			for(int i = 1; i <= MaxClients; ++i) {
				if(!IsClientConnected(i) ||
					IsFakeClient(i) ||
					!IsClientAuthorized(i)) {
					continue;
				}

				if(player_inventory_equipped[i] != null) {
					int len = player_inventory_equipped[i].Length;
					for(int j = 0; j < len; ++j) {
						player_inventory_equipped[i].GetArray(j, plrinfo, sizeof(PlayerItemInfo));

						if(bucket.FindValue(plrinfo.idx) == -1) {
							continue;
						}

						loaded_ids.Push(plrinfo.id);
					}
				}

				int accid = GetSteamAccountID(i);

				int query_len = econ_db.Format(query, QUERY_STR_MAX,
					"select id,item,equipped from player_inventory " ...
					" where " ...
					" accid=%i and item in ("
					,accid
				);

				char str[10];

				int len = bucket.Length;
				for(int j = 0; j < len; ++j) {
					int idx = bucket.Get(j);
					int item_id = items.Get(idx, ItemInfo::id);

					IntToString(item_id, str, sizeof(str));

					query_len += StrCat(query, QUERY_STR_MAX, str);
					query_len += StrCat(query, QUERY_STR_MAX, ",");
				}

				query[query_len-1] = ')';

				if(loaded_ids.Length > 0) {
					query_len += StrCat(query, QUERY_STR_MAX, " and id not in (");

					len = loaded_ids.Length;
					for(int j = 0; j < len; ++j) {
						int id = loaded_ids.Get(j);

						IntToString(id, str, sizeof(str));

						query_len += StrCat(query, QUERY_STR_MAX, str);
						query_len += StrCat(query, QUERY_STR_MAX, ",");
					}

					loaded_ids.Clear();

					query[query_len-1] = ')';
				}

				query[query_len] = ';';
				query[++query_len] = '\0';

				tr.AddQuery(query, GetClientUserId(i));
			}

			econ_db.Execute(tr, cache_player_inventory_late, transaction_error);

			delete loaded_ids;
		}
	}

	return 0;
}

static int native_econ_item_settings(Handle plugin, int params)
{
	int idx = GetNativeCell(1);

	return items.Get(idx, ItemInfo::settings);
}

static int native_econ_find_category(Handle plugin, int params)
{
	int parent = GetNativeCell(1);

	int length = 0;
	GetNativeStringLength(2, length);
	char[] name = new char[++length];
	GetNativeString(2, name, length);

	if(parent != -1) {
		ItemCategoryInfo parent_info;
		categories.GetArray(parent, parent_info, sizeof(ItemCategoryInfo));

		if(!parent_info.childs) {
			return -1;
		}

		ItemCategoryInfo child_info;

		int len = parent_info.childs.Length;
		for(int i = 0; i < len; ++i) {
			int child_idx = parent_info.childs.Get(i);

			categories.GetArray(child_idx, child_info, sizeof(ItemCategoryInfo));

			if(StrEqual(child_info.name, name)) {
				return child_idx;
			}
		}
	} else {
		ItemCategoryInfo info;

		int len = categories.Length;
		for(int i = 0; i < len; ++i) {
			categories.GetArray(i, info, sizeof(ItemCategoryInfo));
			if(info.parent_id != -1) {
				continue;
			}

			if(StrEqual(info.name, name)) {
				return i;
			}
		}
	}

	return -1;
}

static void query_item_category_added(Database db, DBResultSet results, const char[] error, DataPack data)
{
	if(results == null) {
		LogError("%s", error);
		return;
	}

	data.Reset();

	char name[ECON_MAX_ITEM_NAME];
	data.ReadString(name, ECON_MAX_ITEM_NAME);

	int parent_id = data.ReadCell();

	Handle plugin = data.ReadCell();
	Function registered = data.ReadFunction();

	delete data;

	int id = results.InsertId;

	int idx = category_loaded(id, name, parent_id);

	if(parent_id != -1) {
		category_handle_parent(idx, name, parent_id);
	}

	if(registered != INVALID_FUNCTION) {
		Call_StartFunction(plugin, registered);
		Call_PushCell(idx);
		Call_Finish();
	}
}

static int native_econ_register_category(Handle plugin, int params)
{
	int length = 0;
	GetNativeStringLength(1, length);
	char[] name = new char[++length];
	GetNativeString(1, name, length);

	int parent = GetNativeCell(2);
	int parent_id = ((parent != -1) ? cache_idx_to_cat_id(parent) : -1);

	Function registered = GetNativeFunction(3);

	char query[QUERY_STR_MAX];
	if(parent_id != -1) {
		econ_db.Format(query, QUERY_STR_MAX,
			"insert into item_category " ...
			" (name,parent) " ...
			" values " ...
			" ('%s',%i) " ...
			";"
			,name,parent_id
		);
	} else {
		econ_db.Format(query, QUERY_STR_MAX,
			"insert into item_category " ...
			" (name,parent) " ...
			" values " ...
			" ('%s',null) " ...
			";"
			,name
		);
	}
	DataPack data = new DataPack();
	data.WriteString(name);
	data.WriteCell(parent_id);
	data.WriteCell(plugin);
	data.WriteFunction(registered);
	econ_db.Query(query_item_category_added, query, data);

	return 0;
}

static int native_econ_find_item(Handle plugin, int params)
{
	int category = GetNativeCell(1);

	int length = 0;
	GetNativeStringLength(2, length);
	char[] name = new char[++length];
	GetNativeString(2, name, length);

	ArrayList cat_items = categories.Get(category, ItemCategoryInfo::items);

	ItemInfo info;

	int len = cat_items.Length;
	for(int i = 0; i < len; ++i) {
		int idx = cat_items.Get(i);

		items.GetArray(idx, info, sizeof(ItemInfo));

		if(StrEqual(info.name, name)) {
			return idx;
		}
	}

	return -1;
}

static void query_item_added(Database db, DBResultSet results, const char[] error, DataPack data)
{
	if(results == null) {
		LogError("%s", error);
		return;
	}

	data.Reset();

	int cat_id = data.ReadCell();

	char name[ECON_MAX_ITEM_NAME];
	data.ReadString(name, ECON_MAX_ITEM_NAME);

	char description[ECON_MAX_ITEM_DESCRIPTION];
	data.ReadString(description, ECON_MAX_ITEM_DESCRIPTION);

	char classname[ECON_MAX_ITEM_CLASSNAME];
	data.ReadString(classname, ECON_MAX_ITEM_CLASSNAME);

	int price = data.ReadCell();

	StringMap settings = data.ReadCell();

	delete data;

	int id = results.InsertId;

	int idx = item_loaded(id, cat_id, name, description, classname, price);

	if(settings != null) {
		Transaction tr = new Transaction();

		char sett_name[ECON_MAX_ITEM_SETTING_NAME];
		char sett_value[ECON_MAX_ITEM_SETTING_VALUE];

		char query[QUERY_STR_MAX];

		StringMapSnapshot snap = settings.Snapshot();
		int len = snap.Length;
		for(int i = 0; i < len; ++i) {
			snap.GetKey(i, sett_name, ECON_MAX_ITEM_SETTING_NAME);

			if(settings.GetString(sett_name, sett_value, ECON_MAX_ITEM_SETTING_VALUE)) {
				econ_db.Format(query, QUERY_STR_MAX,
					"insert into item_setting " ...
					" (item,name,value) " ...
					" values " ...
					" (%i,'%s','%s') " ...
					";"
					,id,sett_name,sett_value
				);
				tr.AddQuery(query);

				item_setting_loaded(id, sett_name, sett_value);
			}
		}
		delete snap;

		econ_db.Execute(tr, INVALID_FUNCTION, transaction_error);
	}

	int hndlr_idx = -1;
	if(item_handlers_map.GetValue(classname, hndlr_idx)) {
		ItemHandler hndlr;
		item_handlers.GetArray(hndlr_idx, hndlr, sizeof(ItemHandler));

		hndlr.items.Push(idx);

		Call_StartForward(hndlr.cache_fwd);
		Call_PushString(classname);
		Call_PushCell(idx);
		Call_PushCell(settings);
		Call_Finish();

		Menu menu = items.Get(idx, ItemInfo::shop_menu);

		current_menu_type = 1;
		current_menu = menu;

		Call_StartForward(hndlr.menu_fwd);
		Call_PushString(classname);
		Call_PushCell(idx);
		Call_Finish();

		current_menu_type = 0;
		current_menu = null;
	}

	delete settings;
}

static int native_econ_register_item(Handle plugin, int params)
{
	int category = GetNativeCell(1);
	int cat_id = cache_idx_to_cat_id(category);

	int length = 0;
	GetNativeStringLength(2, length);
	char[] name = new char[++length];
	GetNativeString(2, name, length);

	length = 0;
	GetNativeStringLength(3, length);
	char[] description = new char[++length];
	GetNativeString(3, description, length);

	length = 0;
	GetNativeStringLength(4, length);
	char[] classname = new char[++length];
	GetNativeString(4, classname, length);

	int price = GetNativeCell(5);

	StringMap settings = GetNativeCell(6);

	char query[QUERY_STR_MAX];
	econ_db.Format(query, QUERY_STR_MAX,
		"insert into item " ...
		" (category,name,description,classname,price) " ...
		" values " ...
		" (%i,'%s','%s','%s',%i) " ...
		";"
		,cat_id,name,description,classname,price
	);
	DataPack data = new DataPack();
	data.WriteCell(cat_id);
	data.WriteString(name);
	data.WriteString(description);
	data.WriteString(classname);
	data.WriteCell(price);
	data.WriteCell(settings);
	econ_db.Query(query_item_added, query, data);

	return 0;
}

static int native_econ_set_item_price(Handle plugin, int params)
{
	int idx = GetNativeCell(1);
	int item_id = cache_idx_to_item_id(idx);

	int price = GetNativeCell(2);

	char query[QUERY_STR_MAX];
	econ_db.Format(query, QUERY_STR_MAX,
		"update item " ...
		" set price=%i " ...
		" where " ...
		" id=%i " ...
		";"
		,price,item_id
	);
	econ_db.Query(query_error, query);

	items.Set(idx, price, ItemInfo::price);

	return 0;
}

static int native_econ_set_item_description(Handle plugin, int params)
{
	int idx = GetNativeCell(1);
	int item_id = cache_idx_to_item_id(idx);

	int length = 0;
	GetNativeStringLength(2, length);
	char[] description = new char[++length];
	GetNativeString(2, description, length);

	char query[QUERY_STR_MAX];
	econ_db.Format(query, QUERY_STR_MAX,
		"update item set" ...
		" description='%s' " ...
		" where " ...
		" id=%i " ...
		";"
		,description,item_id
	);
	econ_db.Query(query_error, query);

	ItemInfo info;
	items.GetArray(idx, info, sizeof(ItemInfo));
	strcopy(info.desc, ECON_MAX_ITEM_DESCRIPTION, description);
	items.SetArray(idx, info, sizeof(ItemInfo));

	return 0;
}

static int native_econ_set_item_setting(Handle plugin, int params)
{
	int idx = GetNativeCell(1);
	int item_id = cache_idx_to_item_id(idx);

	int length = 0;
	GetNativeStringLength(2, length);
	char[] name = new char[++length];
	GetNativeString(2, name, length);

	length = 0;
	GetNativeStringLength(3, length);
	char[] value = new char[++length];
	GetNativeString(3, value, length);

	char query[QUERY_STR_MAX];
	econ_db.Format(query, QUERY_STR_MAX,
		"replace into item_setting set " ...
		" item=%i,name='%s',value='%s' " ...
		";"
		,item_id,name,value
	);
	econ_db.Query(query_error, query);

	StringMap settings = items.Get(idx, ItemInfo::settings);
	settings.SetString(name, value);

	return 0;
}

static int native_econ_set_item_settings(Handle plugin, int params)
{
	int idx = GetNativeCell(1);
	int item_id = cache_idx_to_item_id(idx);

	StringMap settings = GetNativeCell(2);

	Transaction tr = new Transaction();

	char sett_name[ECON_MAX_ITEM_SETTING_NAME];
	char sett_value[ECON_MAX_ITEM_SETTING_VALUE];

	char query[QUERY_STR_MAX];

	StringMap item_settings = items.Get(idx, ItemInfo::settings);

	StringMapSnapshot snap = settings.Snapshot();
	int len = snap.Length;
	for(int i = 0; i < len; ++i) {
		snap.GetKey(i, sett_name, ECON_MAX_ITEM_SETTING_NAME);

		if(settings.GetString(sett_name, sett_value, ECON_MAX_ITEM_SETTING_VALUE)) {
			econ_db.Format(query, QUERY_STR_MAX,
				"replace into item_setting set " ...
				" item=%i,name='%s',value='%s' " ...
				";"
				,item_id,sett_name,sett_value
			);
			tr.AddQuery(query);

			item_settings.SetString(sett_name, sett_value);
		}
	}
	delete snap;

	delete settings;

	econ_db.Execute(tr, INVALID_FUNCTION, transaction_error);

	return 0;
}

static int native_econ_menu_add_item(Handle plugin, int params)
{
	int length = 0;
	GetNativeStringLength(1, length);
	char[] user_display = new char[++length];
	GetNativeString(1, user_display, length);

	if(current_menu == null) {
		return 0;
	}

	if(current_menu_type == 1) {
		int title_len = (ECON_SHOP_ITEM_TITLE_LEN + 6 + (++length) + 2);
		char[] new_title = new char[title_len];
		current_menu.GetTitle(new_title, title_len);

		StrCat(new_title, title_len, "\n    ");
		StrCat(new_title, title_len, user_display);
		StrCat(new_title, title_len, "\n ");

		current_menu.SetTitle(new_title);
	} else if(current_menu_type == 2) {
		int title_len = (ECON_INV_ITEM_TITLE_LEN + 6 + (++length) + 2);
		char[] new_title = new char[title_len];
		current_menu.GetTitle(new_title, title_len);

		StrCat(new_title, title_len, "\n    ");
		StrCat(new_title, title_len, user_display);
		StrCat(new_title, title_len, "\n ");

		current_menu.SetTitle(new_title);
	}

	return 0;
}

static int native_econ_get_item_name(Handle plugin, int params)
{
	int idx = GetNativeCell(1);

	ItemInfo info;
	items.GetArray(idx, info, sizeof(ItemInfo));

	int len = GetNativeCell(3);

	SetNativeString(2, info.name, len);

	return 0;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("economy");
	item_handlers = new ArrayList(sizeof(ItemHandler));
	item_handlers_map = new StringMap();
	item_class_buckets = new StringMap();
	CreateNative("econ_register_item_class", native_econ_register_item_class);
	CreateNative("econ_item_settings", native_econ_item_settings);
	CreateNative("econ_find_category", native_econ_find_category);
	CreateNative("econ_register_category", native_econ_register_category);
	CreateNative("econ_find_item", native_econ_find_item);
	CreateNative("econ_register_item", native_econ_register_item);
	CreateNative("econ_set_item_price", native_econ_set_item_price);
	CreateNative("econ_set_item_description", native_econ_set_item_description);
	CreateNative("econ_set_item_setting", native_econ_set_item_setting);
	CreateNative("econ_set_item_settings", native_econ_set_item_settings);
	CreateNative("econ_menu_add_item", native_econ_menu_add_item);
	CreateNative("econ_get_item_name", native_econ_get_item_name);
	return APLRes_Success;
}

static void database_connect(Database db, const char[] error, any data)
{
	if(db == null) {
		LogError("%s", error);
		return;
	}

	econ_db = db;
	econ_db.SetCharset("utf8");

	Transaction tr = new Transaction();

	char query[QUERY_STR_MAX];
	econ_db.Format(query, QUERY_STR_MAX,
		"create table if not exists item_category ( " ...
		" id int primary key auto_increment, " ...
		" name varchar(%i) not null, " ...
		" parent int default null, " ...
		" foreign key (parent) references item_category(id) " ...
		");"
		,ECON_MAX_ITEM_CATEGORY_NAME
	);
	tr.AddQuery(query);

	econ_db.Format(query, QUERY_STR_MAX,
		"create table if not exists item ( " ...
		" id int primary key auto_increment, " ...
		" category int not null, " ...
		" foreign key (category) references item_category(id), " ...
		" name varchar(%i) not null, " ...
		" description varchar(%i) not null, " ...
		" classname varchar(%i) not null, " ...
		" price int not null " ...
		");"
		,ECON_MAX_ITEM_NAME,
		ECON_MAX_ITEM_DESCRIPTION,
		ECON_MAX_ITEM_CLASSNAME
	);
	tr.AddQuery(query);

	econ_db.Format(query, QUERY_STR_MAX,
		"create table if not exists item_setting ( " ...
		" item int not null, " ...
		" foreign key (item) references item(id), " ...
		" name varchar(%i) not null, " ...
		" value varchar(%i) not null, " ...
		" unique(item, name) " ...
		");"
		,ECON_MAX_ITEM_SETTING_NAME,
		ECON_MAX_ITEM_SETTING_VALUE
	);
	tr.AddQuery(query);

	tr.AddQuery(
		"create table if not exists player_currency ( " ...
		" accid int primary key, " ...
		" amount int not null " ...
		");"
	);

	tr.AddQuery(
		"create table if not exists player_inventory ( " ...
		" id int primary key auto_increment, " ...
		" accid int not null, " ...
		" item int not null, " ...
		" foreign key (item) references item(id), " ...
		" equipped tinyint not null " ...
		");"
	);

	tr.AddQuery(
		"select * from item_category;"
	);

	tr.AddQuery(
		"select * from item;"
	);

	tr.AddQuery(
		"select * from item_setting;"
	);

	econ_db.Execute(tr, cache_data, transaction_error);
}

public void OnMapStart()
{
	PrecacheScriptSound("MVM.MoneyPickup");
	PrecacheScriptSound("MVM.MoneyVanish");
	PrecacheScriptSound("MVM.PlayerUpgraded");
	PrecacheScriptSound("Credits.Updated");
	PrecacheScriptSound("music.mvm_upgrade_machine");
}

static void cache_data(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	item_id_cache_idx_map = new StringMap();
	items = new ArrayList(sizeof(ItemInfo));
	category_id_cache_idx_map = new StringMap();
	categories = new ArrayList(sizeof(ItemCategoryInfo));

	shop_menu = new Menu(menuhandler_shop, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem|MenuAction_DisplayItem|MenuAction_Display);
	shop_menu.SetTitle("");
	shop_menu.AddItem("", "");

	handle_result_set(results[numQueries-3], cache_categories);

	ItemCategoryInfo cat_info;

	int len = categories.Length;
	for(int i = 0; i < len; ++i) {
		categories.GetArray(i, cat_info, sizeof(ItemCategoryInfo));
		if(cat_info.parent_id == -1) {
			continue;
		}

		category_handle_parent(i, cat_info.name, cat_info.parent_id);
	}

	handle_result_set(results[numQueries-2], cache_items);
	handle_result_set(results[numQueries-1], cache_items_settings);

	char classname[ECON_MAX_ITEM_CLASSNAME];

	ItemHandler hndlr;

	StringMapSnapshot snap = item_class_buckets.Snapshot();
	len = snap.Length;
	for(int i = 0; i < len; ++i) {
		snap.GetKey(i, classname, ECON_MAX_ITEM_CLASSNAME);

		int hndlr_idx = -1;
		ArrayList bucket = null;
		if(item_class_buckets.GetValue(classname, bucket) &&
			item_handlers_map.GetValue(classname, hndlr_idx)) {
			item_handlers.GetArray(hndlr_idx, hndlr, sizeof(ItemHandler));

			int len2 = bucket.Length;
			for(int j = 0; j < len2; ++j) {
				int idx = bucket.Get(j);

				StringMap settings = items.Get(idx, ItemInfo::settings);
				Menu menu = items.Get(idx, ItemInfo::shop_menu);

				hndlr.items.Push(idx);

				Call_StartForward(hndlr.cache_fwd);
				Call_PushString(classname);
				Call_PushCell(idx);
				Call_PushCell(settings);
				Call_Finish();

				current_menu_type = 1;
				current_menu = menu;

				Call_StartForward(hndlr.menu_fwd);
				Call_PushString(classname);
				Call_PushCell(idx);
				Call_Finish();

				current_menu_type = 0;
				current_menu = null;
			}
		}
	}
	delete snap;

	for(int i = 1; i <= MaxClients; ++i) {
		if(IsClientConnected(i) && !IsFakeClient(i) && IsClientAuthorized(i)) {
			query_player_data(i);
		}
	}

	items_loaded = true;

	Call_StartForward(fwd_loaded);
	Call_Finish();
}

static void handle_result_set(DBResultSet set, Function func, any data=0)
{
	if(!set.HasResults) {
		LogError("void result");
		return;
	}

	for(int i = 0; i < set.RowCount; ++i) {
		if(!set.FetchRow()) {
			LogError("fetch failed");
			return;
		}

		Call_StartFunction(null, func);
		Call_PushCell(set);
		Call_PushCell(data);
		Call_Finish();
	}
}

static int item_id_to_cache_idx(int id)
{
	char str[5];
	pack_int_in_str(id, str);

	int idx = -1;
	item_id_cache_idx_map.GetValue(str, idx);

	return idx;
}

static int cat_id_to_cache_idx(int id)
{
	char str[5];
	pack_int_in_str(id, str);

	int idx = -1;
	category_id_cache_idx_map.GetValue(str, idx);

	return idx;
}

static int cache_idx_to_cat_id(int idx)
{
	return categories.Get(idx, ItemCategoryInfo::id);
}

static int cache_idx_to_item_id(int idx)
{
	return items.Get(idx, ItemInfo::id);
}

static void category_handle_parent(int idx, const char[] name, int parent_id)
{
	int parent_idx = categories.FindValue(parent_id, ItemCategoryInfo::id);
	if(parent_idx == -1) {
		return;
	}

	categories.Set(idx, parent_idx, ItemCategoryInfo::parent_idx);

	ItemCategoryInfo parent_info;
	categories.GetArray(parent_idx, parent_info, sizeof(ItemCategoryInfo));

	if(parent_info.childs == null) {
		parent_info.childs = new ArrayList();
		categories.SetArray(parent_idx, parent_info, sizeof(ItemCategoryInfo));
	}

	parent_info.childs.Push(idx);

	char str[10];
	pack_int_in_str(idx, str, 0);
	pack_int_in_str(1, str, 4);
	parent_info.shop_menu.AddItem(str, name);
}

static int category_loaded(int id, const char[] name, int parent_id)
{
	ItemCategoryInfo info;

	info.id = id;
	strcopy(info.name, ECON_MAX_ITEM_CATEGORY_NAME, name);

	info.parent_id = parent_id;
	info.parent_idx = -1;

	info.shop_menu = new Menu(menuhandler_shop_cat, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem|MenuAction_DisplayItem);
	info.shop_menu.ExitBackButton = true;

	char category_menu_title[10 + ECON_MAX_ITEM_CATEGORY_NAME];
	Format(category_menu_title, sizeof(category_menu_title), "Category: %s", info.name);
	info.shop_menu.SetTitle(category_menu_title);

	info.items = new ArrayList();

	int idx = categories.PushArray(info, sizeof(ItemCategoryInfo));

	char str[5];
	pack_int_in_str(info.id, str);
	category_id_cache_idx_map.SetValue(str, idx);

	pack_int_in_str(idx, str);
	info.shop_menu.AddItem(str, "", ITEMDRAW_IGNORE);

	if(parent_id == -1) {
		pack_int_in_str(idx, str);
		shop_menu.AddItem(str, info.name);
	}

	return idx;
}

static void cache_categories(DBResultSet set)
{
	int id = set.FetchInt(0);

	char name[ECON_MAX_ITEM_NAME];
	set.FetchString(1, name, ECON_MAX_ITEM_NAME);

	int parent_id = (set.IsFieldNull(2) ? -1 : set.FetchInt(2));

	category_loaded(id, name, parent_id);
}

static int item_loaded(int id, int cat_id, const char[] name, const char[] desc, const char[] classname, int price)
{
	ItemInfo info;
	info.settings = new StringMap();

	info.id = id;

	int cat_idx = cat_id_to_cache_idx(cat_id);

	info.category = cat_idx;

	strcopy(info.name, ECON_MAX_ITEM_NAME, name);
	strcopy(info.desc, ECON_MAX_ITEM_DESCRIPTION, desc);
	strcopy(info.classname, ECON_MAX_ITEM_CLASSNAME, classname);

	info.price = price;

	info.shop_menu = new Menu(menuhandler_shop_cat_item, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem);
	info.shop_menu.ExitBackButton = true;

	int display_price = info.price;
	if(display_price == -2) {
		display_price = 999999999;
	}

	char item_menu_title[ECON_SHOP_ITEM_TITLE_LEN];
	StrCat(item_menu_title, sizeof(item_menu_title), "Item: ");
	StrCat(item_menu_title, sizeof(item_menu_title), info.name);
	StrCat(item_menu_title, sizeof(item_menu_title), "\n ");

	if(info.desc[0] != '\0') {
		StrCat(item_menu_title, sizeof(item_menu_title), "\n    ");
		StrCat(item_menu_title, sizeof(item_menu_title), info.desc);
		StrCat(item_menu_title, sizeof(item_menu_title), "\n ");
	}

	if(display_price >= 0) {
		StrCat(item_menu_title, sizeof(item_menu_title), "\n    ");
		StrCat(item_menu_title, sizeof(item_menu_title), "Price: ");

		char price_str[ECON_SHOP_PRICE_STR_LEN];
		IntToString(display_price, price_str, sizeof(price_str));

		StrCat(item_menu_title, sizeof(item_menu_title), price_str);

		StrCat(item_menu_title, sizeof(item_menu_title), "\n ");
	}

	info.shop_menu.SetTitle(item_menu_title);

	int idx = items.PushArray(info, sizeof(ItemInfo));

	ArrayList cat_items = categories.Get(cat_idx, ItemCategoryInfo::items);
	cat_items.Push(idx);

	char str[10];
	pack_int_in_str(info.id, str);
	item_id_cache_idx_map.SetValue(str, idx);

	if(display_price >= 0) {
		Menu cat_menu = categories.Get(cat_idx, ItemCategoryInfo::shop_menu);

		pack_int_in_str(idx, str, 0);
		pack_int_in_str(0, str, 4);
		cat_menu.AddItem(str, info.name);

		//pack_int_in_str(idx, str, 0);
		//info.shop_menu.AddItem(str, "Preview");

		pack_int_in_str(idx, str, 0);
		info.shop_menu.AddItem(str, "Buy", ITEMDRAW_DISABLED);
	}

	ArrayList bucket = null;
	if(!item_class_buckets.GetValue(info.classname, bucket)) {
		bucket = new ArrayList();
		item_class_buckets.SetValue(info.classname, bucket);
	}

	bucket.Push(idx);

	return idx;
}

static void cache_items(DBResultSet set)
{
	int id = set.FetchInt(0);
	int cat_id = set.FetchInt(1);

	char name[ECON_MAX_ITEM_NAME];
	set.FetchString(2, name, ECON_MAX_ITEM_NAME);

	char desc[ECON_MAX_ITEM_DESCRIPTION];
	set.FetchString(3, desc, ECON_MAX_ITEM_DESCRIPTION);

	char classname[ECON_MAX_ITEM_CLASSNAME];
	set.FetchString(4, classname, ECON_MAX_ITEM_CLASSNAME);

	int price = set.FetchInt(5);

	item_loaded(id, cat_id, name, desc, classname, price);
}

static void item_setting_loaded(int id, const char[] name, const char[] value)
{
	int idx = item_id_to_cache_idx(id);

	StringMap settings = items.Get(idx, ItemInfo::settings);

	settings.SetString(name, value);
}

static void cache_items_settings(DBResultSet set)
{
	int id = set.FetchInt(0);

	char name[ECON_MAX_ITEM_SETTING_NAME];
	set.FetchString(1, name, ECON_MAX_ITEM_SETTING_NAME);

	char value[ECON_MAX_ITEM_SETTING_VALUE];
	set.FetchString(2, value, ECON_MAX_ITEM_SETTING_VALUE);

	item_setting_loaded(id, name, value);
}

static void cache_player_currency(DBResultSet set, int usrid)
{
	int client = GetClientOfUserId(usrid);
	if(client == 0) {
		return;
	}

	int amount = set.FetchInt(0);

	player_currency[client] = amount;
}

static void player_item_loaded(int client, int idx, int id, bool equipped)
{
	PlayerItemInfo plrinfo;
	plrinfo.idx = idx;
	plrinfo.id = id;

	if(equipped) {
		player_inventory_equipped[client].PushArray(plrinfo, sizeof(PlayerItemInfo));
	} else {
		player_inventory[client].PushArray(plrinfo, sizeof(PlayerItemInfo));
	}

	ItemInfo info;
	items.GetArray(idx, info, sizeof(ItemInfo));

	int hndlr_idx = -1;
	if(item_handlers_map.GetValue(info.classname, hndlr_idx)) {
		ItemHandler hndlr;
		item_handlers.GetArray(hndlr_idx, hndlr, sizeof(ItemHandler));

		if(!hndlr.equipable) {
			Call_StartForward(hndlr.handle_fwd);
			Call_PushCell(client);
			Call_PushString(info.classname);
			Call_PushCell(idx);
			Call_PushCell(id);
			Call_PushCell(econ_item_equip);
			Call_Finish();
		} else if(equipped || !hndlr.equipable) {
			Call_StartForward(hndlr.handle_fwd);
			Call_PushCell(client);
			Call_PushString(info.classname);
			Call_PushCell(idx);
			Call_PushCell(id);
			Call_PushCell(econ_item_equip);
			Call_Finish();

			if(econ_player_state_valid(client)) {
				Call_StartForward(hndlr.handle_fwd);
				Call_PushCell(client);
				Call_PushString(info.classname);
				Call_PushCell(idx);
				Call_PushCell(id);
				Call_PushCell(econ_item_apply);
				Call_Finish();
			}
		}
	}

	add_item_to_player_inv_menu(client, id, idx);
}

static void cache_player_inventory(DBResultSet set, int usrid)
{
	int client = GetClientOfUserId(usrid);
	if(client == 0) {
		return;
	}

	int item_id = set.FetchInt(1);
	int idx = item_id_to_cache_idx(item_id);

	int id = set.FetchInt(0);

	bool equipped = (set.FetchInt(2) != 0);

	player_item_loaded(client, idx, id, equipped);
}

static bool player_has_item(int client, int idx)
{
	if(player_inventory[client] != null && (player_inventory[client].FindValue(idx, PlayerItemInfo::idx) != -1)) {
		return true;
	}

	if(player_inventory_equipped[client] != null && (player_inventory_equipped[client].FindValue(idx, PlayerItemInfo::idx) != -1)) {
		return true;
	}

	return false;
}

static bool player_has_item_equipped(int client, int id)
{
	if(player_inventory_equipped[client] != null && (player_inventory_equipped[client].FindValue(id, PlayerItemInfo::id) != -1)) {
		return true;
	}

	return false;
}

static void set_item_equipped(int client, int idx, int id, bool equipped)
{
	char query[QUERY_STR_MAX];
	econ_db.Format(query, QUERY_STR_MAX,
		"update player_inventory set " ...
		" equipped=%i " ...
		" where " ...
		" id=%i " ...
		";"
		,(equipped ? 1 : 0),
		id
	);
	econ_db.Query(query_error, query);

	if(!equipped) {
		handle_player_item(client, idx, id, econ_item_remove);
	}
	handle_player_item(client, idx, id, (equipped ? econ_item_equip : econ_item_unequip));
	if(equipped) {
		handle_player_item(client, idx, id, econ_item_apply);
	}
}

static void StopGameSound(int client, const char[] sound, int entity = SOUND_FROM_PLAYER)
{
	int level;
	float volume;
	int pitch;

	int channel;
	char sample[PLATFORM_MAX_PATH];

	if(GetGameSoundParams(sound, channel, level, volume, pitch, sample, sizeof(sample), entity)) {
		StopSound(client, channel, sample);
	}
}

static int menuhandler_inv_cat_item(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action) {
		case MenuAction_Select: {
			char str[10];
			menu.GetItem(param2, str, sizeof(str));

			int idx = unpack_int_in_str(str, 0);
			int id = unpack_int_in_str(str, 4);

			set_item_equipped(param1, idx, id, !player_has_item_equipped(param1, id));

			menu.DisplayAt(param1, menu.Selection, MENU_TIME_FOREVER);

			on_player_close_inv(param1);
		}
		case MenuAction_Cancel: {
			if(param2 == MenuCancel_ExitBack) {
				char str[10];
				menu.GetItem(menu.ItemCount-1, str, sizeof(str));

				int idx = unpack_int_in_str(str, 0);

				int catidx = items.Get(idx, ItemInfo::category);

				pack_int_in_str(catidx, str, 0);

				PlayerInventoryCategory plrinvcat;
				if(player_inventory_categories[param1].GetArray(str, plrinvcat, sizeof(PlayerInventoryCategory))) {
					plrinvcat.menu.Display(param1, MENU_TIME_FOREVER);
				} else {
					player_inventory_menu[param1].Display(param1, MENU_TIME_FOREVER);
				}
			} else {
				on_player_close_inv(param1);
			}
		}
		case MenuAction_DisplayItem: {
			if(param2 == menu.ItemCount-1) {
				char str[10];
				menu.GetItem(param2, str, sizeof(str));

				int id = unpack_int_in_str(str, 4);

				if(player_has_item_equipped(param1, id)) {
					return RedrawMenuItem("Unequip");
				} else {
					return RedrawMenuItem("Equip");
				}
			}
			return 0;
		}
		case MenuAction_End: {
			if(param1 != MenuEnd_Selected) {
				delete menu;
			}
		}
	}

	return 0;
}

static int menuhandler_inv_cat(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action) {
		case MenuAction_Select: {
			char str[15];
			menu.GetItem(param2, str, sizeof(str));

			bool is_sub_cat = (unpack_int_in_str(str, 0) != 0);

			if(!is_sub_cat) {
				int idx = unpack_int_in_str(str, 4);
				int id = unpack_int_in_str(str, 8);

				ItemInfo info;
				items.GetArray(idx, info, sizeof(ItemInfo));

				Menu inv_menu = new Menu(menuhandler_inv_cat_item, MENU_ACTIONS_DEFAULT|MenuAction_DisplayItem);
				inv_menu.ExitBackButton = true;

				char item_menu_title[ECON_INV_ITEM_TITLE_LEN];
				StrCat(item_menu_title, sizeof(item_menu_title), "Item: ");
				StrCat(item_menu_title, sizeof(item_menu_title), info.name);
				StrCat(item_menu_title, sizeof(item_menu_title), "\n ");

				if(info.desc[0] != '\0') {
					StrCat(item_menu_title, sizeof(item_menu_title), "\n    ");
					StrCat(item_menu_title, sizeof(item_menu_title), info.desc);
					StrCat(item_menu_title, sizeof(item_menu_title), "\n ");
				}

				inv_menu.SetTitle(item_menu_title);

				bool equipable = false;

				int hndlr_idx = -1;
				if(item_handlers_map.GetValue(info.classname, hndlr_idx)) {
					ItemHandler hndlr;
					item_handlers.GetArray(hndlr_idx, hndlr, sizeof(ItemHandler));

					equipable = hndlr.equipable;

					current_menu_type = 2;
					current_menu = inv_menu;

					Call_StartForward(hndlr.menu_fwd);
					Call_PushString(info.classname);
					Call_PushCell(idx);
					Call_Finish();

					current_menu_type = 0;
					current_menu = null;
				}

				if(equipable) {
					pack_int_in_str(idx, str, 0);
					pack_int_in_str(id, str, 4);
					inv_menu.AddItem(str, "Equip");
				}

				inv_menu.Display(param1, MENU_TIME_FOREVER);
			} else {
				int idx = unpack_int_in_str(str, 4);

				pack_int_in_str(idx, str, 0);

				PlayerInventoryCategory plrinvcat;
				if(player_inventory_categories[param1].GetArray(str, plrinvcat, sizeof(PlayerInventoryCategory))) {
					plrinvcat.menu.Display(param1, MENU_TIME_FOREVER);
				} else {
					player_inventory_menu[param1].Display(param1, MENU_TIME_FOREVER);
				}
			}
		}
		case MenuAction_Cancel: {
			if(param2 == MenuCancel_ExitBack) {
				char str[5];
				menu.GetItem(0, str, sizeof(str));

				int idx = unpack_int_in_str(str);

				int parent_idx = categories.Get(idx, ItemCategoryInfo::parent_idx);
				if(parent_idx == -1) {
					player_inventory_menu[param1].Display(param1, MENU_TIME_FOREVER);
				} else {
					pack_int_in_str(parent_idx, str, 0);

					PlayerInventoryCategory plrinvcat;
					if(player_inventory_categories[param1].GetArray(str, plrinvcat, sizeof(PlayerInventoryCategory))) {
						plrinvcat.menu.Display(param1, MENU_TIME_FOREVER);
					} else {
						player_inventory_menu[param1].Display(param1, MENU_TIME_FOREVER);
					}
				}
			} else {
				on_player_close_inv(param1);
			}
		}
	}

	return 0;
}

static int menuhandler_inv(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action) {
		case MenuAction_Display: {
			char inventory_menu_title[ECON_INV_TITLE_LEN];
			strcopy(inventory_menu_title, sizeof(inventory_menu_title), "Inventory\n    ");

			StrCat(inventory_menu_title, sizeof(inventory_menu_title), "Credits: ");

			char credits_str[ECON_SHOP_CREDITS_STR_LEN];
			IntToString(player_currency[param1], credits_str, sizeof(credits_str));

			StrCat(inventory_menu_title, sizeof(inventory_menu_title), credits_str);

			StrCat(inventory_menu_title, sizeof(inventory_menu_title), "\n ");

			menu.SetTitle(inventory_menu_title);

			if(!playing_shop_music[param1]) {
				on_player_open_inv(param1);
			}
		}
		case MenuAction_Select: {
			char str[5];
			menu.GetItem(param2, str, sizeof(str));

			PlayerInventoryCategory plrinvcat;
			if(player_inventory_categories[param1].GetArray(str, plrinvcat, sizeof(PlayerInventoryCategory))) {
				plrinvcat.menu.Display(param1, MENU_TIME_FOREVER);
			} else {
				player_inventory_menu[param1].Display(param1, MENU_TIME_FOREVER);
			}
		}
		case MenuAction_Cancel: {
			if(param2 == MenuCancel_ExitBack) {
				on_player_close_inv(param1, true);

				if(show_shop_menu(param1)) {
					return 0;
				}
			} else {
				on_player_close_inv(param1);
			}
		}
	}

	return 0;
}

public void TF2_OnConditionRemoved(int client, TFCond condition)
{
	if(condition == TFCond_Taunting) {
		if(player_taunt_stage[client] == 1) {
			player_taunt_stage[client] = 0;
			SetEntProp(client, Prop_Send, "m_bViewingCYOAPDA", 0);
			CancelClientMenu(client, true);
		}
	}
}

static void on_player_open_inv(int client)
{
	playing_shop_music[client] = true;

	if(is_allowed_to_taunt(client)) {
		if(do_animation_taunt_3_stage(client, "ACT_MP_CYOA_PDA_INTRO","ACT_MP_CYOA_PDA_IDLE","ACT_MP_CYOA_PDA_OUTRO")) {
			player_taunt_stage[client] = 1;
			SetEntProp(client, Prop_Send, "m_bViewingCYOAPDA", 1);
		}
	}
}

static void on_player_open_shop(int client)
{
	on_player_open_inv(client);
	EmitGameSoundToClient(client, "music.mvm_upgrade_machine");
}

static void on_player_close_inv(int client, bool open_shop = false)
{
	playing_shop_music[client] = false;

	if(!open_shop) {
		if(player_taunt_stage[client] == 1) {
			player_taunt_stage[client] = 0;
			SetEntProp(client, Prop_Send, "m_bViewingCYOAPDA", 0);
			cancel_taunt(client);
		}
	}
}

static void on_player_close_shop(int client, bool inv = false)
{
	StopGameSound(client, "music.mvm_upgrade_machine");
	playing_shop_music[client] = false;

	if(!inv) {
		on_player_close_inv(client);
	}
}

static bool can_player_buy(int client, int idx, int price)
{
	if(player_has_item(client, idx) ||
		(player_purchase_queue[client].FindValue(idx) != -1)) {
		return false;
	}

	if(price < 0) {
		return false;
	}

	if(player_currency[client] < price) {
		return false;
	}

	return true;
}

static int menuhandler_shop_cat_item(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action) {
		case MenuAction_Select: {
			char str[5];
			menu.GetItem(param2, str, sizeof(str));

			int idx = unpack_int_in_str(str);
			int price = items.Get(idx, ItemInfo::price);

			if(!can_player_buy(param1, idx, price)) {
				menu.DisplayAt(param1, menu.Selection, MENU_TIME_FOREVER);
				return 0;
			}

			EmitGameSoundToClient(param1, "MVM.PlayerUpgraded");

			add_item_to_player_inv(param1, idx);
			modify_player_currency(param1, -price);

			menu.DisplayAt(param1, menu.Selection, MENU_TIME_FOREVER);
		}
		case MenuAction_Cancel: {
			if(param2 == MenuCancel_ExitBack) {
				char str[5];
				menu.GetItem(menu.ItemCount-1, str, sizeof(str));

				int idx = unpack_int_in_str(str);
				int cat_idx = items.Get(idx, ItemInfo::category);

				Menu cat_shop_menu = categories.Get(cat_idx, ItemCategoryInfo::shop_menu);
				cat_shop_menu.Display(param1, MENU_TIME_FOREVER);
			} else {
				on_player_close_shop(param1);
			}
		}
		case MenuAction_DrawItem: {
			if(param2 == menu.ItemCount-1) {
				char str[5];
				menu.GetItem(param2, str, sizeof(str));

				int idx = unpack_int_in_str(str);
				int price = items.Get(idx, ItemInfo::price);

				return (can_player_buy(param1, idx, price) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
			}

			return ITEMDRAW_DISABLED;
		}
	}

	return 0;
}

static int menuhandler_shop_cat(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action) {
		case MenuAction_Select: {
			char str[10];
			menu.GetItem(param2, str, sizeof(str));

			int idx = unpack_int_in_str(str, 0);
			bool is_sub_cat = (unpack_int_in_str(str, 4) != 0);

			if(!is_sub_cat) {
				Menu item_shop_menu = items.Get(idx, ItemInfo::shop_menu);
				item_shop_menu.Display(param1, MENU_TIME_FOREVER);
			} else {
				Menu cat_shop_menu = categories.Get(idx, ItemCategoryInfo::shop_menu);
				cat_shop_menu.Display(param1, MENU_TIME_FOREVER);
			}
		}
		case MenuAction_DrawItem: {
			if(param2 == 0) {
				return ITEMDRAW_IGNORE;
			} else {
				char str[10];
				menu.GetItem(param2, str, sizeof(str));

				int idx = unpack_int_in_str(str, 0);
				bool is_sub_cat = (unpack_int_in_str(str, 4) != 0);

				if(is_sub_cat) {
					Menu cat_shop_menu = categories.Get(idx, ItemCategoryInfo::shop_menu);
					if(cat_shop_menu.ItemCount < 2) {
						return ITEMDRAW_DISABLED;
					}
				}

				return ITEMDRAW_DEFAULT;
			}
		}
		case MenuAction_DisplayItem: {
			if(param2 == 0) {
				return RedrawMenuItem("");
			} else {
				char str[10];
				menu.GetItem(param2, str, sizeof(str));

				int idx = unpack_int_in_str(str, 0);
				bool is_sub_cat = (unpack_int_in_str(str, 4) != 0);

				if(is_sub_cat) {
					ItemCategoryInfo info;
					categories.GetArray(idx, info, sizeof(ItemCategoryInfo));

					if(info.shop_menu.ItemCount < 2) {
						char display[ECON_MAX_ITEM_CATEGORY_NAME + 11];
						strcopy(display, sizeof(display), info.name);
						StrCat(display, sizeof(display), " [No Items]");
						return RedrawMenuItem(display);
					}

					return RedrawMenuItem(info.name);
				}
				return 0;
			}
		}
		case MenuAction_Cancel: {
			if(param2 == MenuCancel_ExitBack) {
				char str[5];
				menu.GetItem(0, str, sizeof(str));

				int idx = unpack_int_in_str(str);

				int parent_idx = categories.Get(idx, ItemCategoryInfo::parent_idx);
				if(parent_idx == -1) {
					shop_menu.Display(param1, MENU_TIME_FOREVER);
				} else {
					Menu parent_menu = categories.Get(parent_idx, ItemCategoryInfo::shop_menu);
					parent_menu.Display(param1, MENU_TIME_FOREVER);
				}
			} else {
				on_player_close_shop(param1);
			}
		}
	}

	return 0;
}

static int menuhandler_shop(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action) {
		case MenuAction_Display: {
			char shop_menu_title[ECON_SHOP_TITLE_LEN];
			strcopy(shop_menu_title, sizeof(shop_menu_title), "Shop\n    ");

			StrCat(shop_menu_title, sizeof(shop_menu_title), "Credits: ");

			char credits_str[ECON_SHOP_CREDITS_STR_LEN];
			IntToString(player_currency[param1], credits_str, sizeof(credits_str));

			StrCat(shop_menu_title, sizeof(shop_menu_title), credits_str);

			StrCat(shop_menu_title, sizeof(shop_menu_title), "\n ");

			menu.SetTitle(shop_menu_title);

			if(!playing_shop_music[param1]) {
				on_player_open_shop(param1);
			}
		}
		case MenuAction_Select: {
			if(param2 == 0) {
				if(show_player_inventory(param1)) {
					on_player_close_shop(param1, true);
				} else {
					menu.DisplayAt(param1, menu.Selection, MENU_TIME_FOREVER);
				}
			} else {
				char str[5];
				menu.GetItem(param2, str, sizeof(str));

				int idx = unpack_int_in_str(str);

				Menu cat_shop_menu = categories.Get(idx, ItemCategoryInfo::shop_menu);
				cat_shop_menu.Display(param1, MENU_TIME_FOREVER);
			}
		}
		case MenuAction_DisplayItem: {
			if(param2 == 0) {
				if(!can_show_player_inventory(param1)) {
					return RedrawMenuItem("Inventory [No Items]\n ");
				}

				return RedrawMenuItem("Inventory\n ");
			} else {
				char str[5];
				menu.GetItem(param2, str, sizeof(str));

				int idx = unpack_int_in_str(str);

				ItemCategoryInfo info;
				categories.GetArray(idx, info, sizeof(ItemCategoryInfo));

				if(info.shop_menu.ItemCount < 2) {
					char display[ECON_MAX_ITEM_CATEGORY_NAME + 11];
					strcopy(display, sizeof(display), info.name);
					StrCat(display, sizeof(display), " [No Items]");
					return RedrawMenuItem(display);
				}

				return RedrawMenuItem(info.name);
			}
		}
		case MenuAction_DrawItem: {
			if(param2 == 0) {
				if(!can_show_player_inventory(param1)) {
					return ITEMDRAW_DISABLED;
				}
			} else {
				char str[5];
				menu.GetItem(param2, str, sizeof(str));

				int idx = unpack_int_in_str(str);

				Menu cat_shop_menu = categories.Get(idx, ItemCategoryInfo::shop_menu);
				if(cat_shop_menu.ItemCount < 2) {
					return ITEMDRAW_DISABLED;
				}
			}
			return ITEMDRAW_DEFAULT;
		}
		case MenuAction_Cancel: {
			on_player_close_shop(param1);
		}
	}

	return 0;
}

static void init_player_vars(int client)
{
	if(player_inventory[client] == null) {
		player_inventory[client] = new ArrayList(sizeof(PlayerItemInfo));
	}
	if(player_inventory_equipped[client] == null) {
		player_inventory_equipped[client] = new ArrayList(sizeof(PlayerItemInfo));
	}

	if(player_inventory_categories[client] == null) {
		player_inventory_categories[client] = new StringMap();
	}

	if(player_inventory_menu[client] == null) {
		player_inventory_menu[client] = new Menu(menuhandler_inv, MENU_ACTIONS_DEFAULT|MenuAction_Display|MenuAction_DisplayItem);
		player_inventory_menu[client].SetTitle("");
		player_inventory_menu[client].ExitBackButton = true;
	}
}

static void cache_player_data(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	int client = GetClientOfUserId(data);
	if(client == 0) {
		return;
	}

	init_player_vars(client);

	handle_result_set(results[numQueries-2], cache_player_currency, queryData[numQueries-2]);
	handle_result_set(results[numQueries-1], cache_player_inventory, queryData[numQueries-1]);
}

static void query_player_data(int client)
{
	if(econ_db == null) {
		return;
	}

	int accid = GetSteamAccountID(client);
	int usrid = GetClientUserId(client);

	Transaction tr = new Transaction();

	char query[QUERY_STR_MAX];
	econ_db.Format(query, QUERY_STR_MAX,
		"select amount from player_currency " ...
		" where " ...
		" accid=%i;"
		,accid
	);
	tr.AddQuery(query, usrid);

	econ_db.Format(query, QUERY_STR_MAX,
		"select id,item,equipped from player_inventory " ...
		" where " ...
		" accid=%i;"
		,accid
	);
	tr.AddQuery(query, usrid);

	econ_db.Execute(tr, cache_player_data, transaction_error, usrid);
}

static const int idle_currency_time = 5;

static Action timer_give_currency(Handle timer, int client)
{
	client = GetClientOfUserId(client);
	if(client == 0) {
		return Plugin_Stop;
	}

	static const int idle_currency = 30;
	modify_player_currency(client, idle_currency);
	CPrintToChat(client, ECON_CHAT_PREFIX ... "You received %i credits for playing on the server for %i minutes! you can spend it on the !shop.", idle_currency, idle_currency_time);

	return Plugin_Continue;
}

public void OnClientAuthorized(int client, const char[] auth)
{
	if(!IsFakeClient(client)) {
		query_player_data(client);
	}
}

public void OnClientPutInServer(int client)
{
	if(!IsFakeClient(client)) {
		player_purchase_queue[client] = new ArrayList();

		player_currency_timer[client] = CreateTimer(float(idle_currency_time * 60), timer_give_currency, GetClientUserId(client), TIMER_REPEAT);
	}
}

public void OnClientDisconnect(int client)
{
	handle_player_inventory(client, econ_item_remove);
	handle_player_inventory(client, econ_item_unequip);

	if(player_currency_timer[client] != null) {
		KillTimer(player_currency_timer[client]);
		player_currency_timer[client] = null;
	}

	playing_shop_music[client] = false;
	player_taunt_stage[client] = 0;

	player_currency[client] = 0;

	delete player_inventory[client];
	delete player_inventory_equipped[client];
	delete player_inventory_menu[client];
	delete player_inventory_categories[client];
	delete player_purchase_queue[client];
}

static bool can_show_player_inventory(int client)
{
	return (player_inventory_menu[client] != null && player_inventory_menu[client].ItemCount > 0);
}

static bool show_player_inventory(int client)
{
	if(player_inventory_menu[client] != null && player_inventory_menu[client].ItemCount > 0) {
		player_inventory_menu[client].Display(client, MENU_TIME_FOREVER);
		return true;
	} else {
		if(player_currency[client] == 1) {
			CPrintToChat(client, ECON_CHAT_PREFIX ... "You dont own any items. Use !shop to buy some. you have 1 credit.");
		} else if(player_currency[client] > 0) {
			CPrintToChat(client, ECON_CHAT_PREFIX ... "You dont own any items. Use !shop to buy some. you have %i credits.", player_currency[client]);
		} else {
			CPrintToChat(client, ECON_CHAT_PREFIX ... "You dont own any items. Use !shop to buy some once you have credits.");
		}
		return false;
	}
}

static Action sm_inventory(int client, int args)
{
	show_player_inventory(client);

	return Plugin_Handled;
}

static bool show_shop_menu(int client)
{
	if(shop_menu != null && shop_menu.ItemCount > 1) {
		shop_menu.Display(client, MENU_TIME_FOREVER);
		return true;
	} else {
		CPrintToChat(client, ECON_CHAT_PREFIX ... "The shop doens't have any items for sale.");
		return false;
	}
}

static Action sm_shop(int client, int args)
{
	show_shop_menu(client);

	return Plugin_Handled;
}