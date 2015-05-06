/*  RetroArch - A frontend for libretro.
 *  Copyright (C) 2013-2014 - Jason Fetters
 *  Copyright (C) 2014-2015 - Jay McCarthy
 * 
 *  RetroArch is free software: you can redistribute it and/or modify it under the terms
 *  of the GNU General Public License as published by the Free Software Found-
 *  ation, either version 3 of the License, or (at your option) any later version.
 *
 *  RetroArch is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 *  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 *  PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with RetroArch.
 *  If not, see <http://www.gnu.org/licenses/>.
 */

#include <objc/runtime.h>

#include <file/file_path.h>
#include <retro_miscellaneous.h>

#include "cocoa_common.h"
#include "../../../input/input_common.h"
#include "../../../input/input_keymaps.h"
#include "../../../input/drivers/cocoa_input.h"

#include "../../../menu/menu_entries.h"
#include "../../../menu/drivers/shared.h"

@protocol RAMenuItemBase
- (UITableViewCell*)cellForTableView:(UITableView*)tableView;
- (void)wasSelectedOnTableView:(UITableView*)tableView ofController:(UIViewController*)controller;
@end

/*********************************************/
/* RAMenuItemBasic                           */
/* A simple menu item that displays a text   */
/* description and calls a block object when */
/* selected.                                 */
/*********************************************/
@interface RAMenuItemBasic : NSObject<RAMenuItemBase>
@property (nonatomic) NSString* description;
@property (nonatomic) id userdata;
@property (copy) void (^action)(id userdata);
@property (copy) NSString* (^detail)(id userdata);

+ (RAMenuItemBasic*)itemWithDescription:(NSString*)description action:(void (^)())action;
+ (RAMenuItemBasic*)itemWithDescription:(NSString*)description action:(void (^)())action detail:(NSString* (^)())detail;
+ (RAMenuItemBasic*)itemWithDescription:(NSString*)description association:(id)userdata action:(void (^)())action detail:(NSString* (^)())detail;

@end

/*********************************************/
/* RAMenuItemGeneralSetting                  */
/* A simple menu item that displays the      */
/* state, and allows editing, of a string or */
/* numeric setting.                          */
/*********************************************/
@interface RAMenuItemGeneralSetting : NSObject<RAMenuItemBase>
@property (nonatomic) rarch_setting_t* setting;
@property (copy) void (^action)();
@property (nonatomic, weak) UITableView* parentTable;
- (id)initWithSetting:(rarch_setting_t*)setting action:(void (^)())action;
@end

/*********************************************/
/* RAMenuItemBooleanSetting                  */
/* A simple menu item that displays the      */
/* state, and allows editing, of a boolean   */
/* setting.                                  */
/*********************************************/
@interface RAMenuItemBooleanSetting : NSObject<RAMenuItemBase>
@property (nonatomic) rarch_setting_t* setting;
@property (copy) void (^action)();
- (id)initWithSetting:(rarch_setting_t*)setting action:(void (^)())action;
@end

/*********************************************/
/* RAMenuItemPathSetting                     */
/* A menu item that displays and allows      */
/* browsing for a path setting.              */
/*********************************************/
@interface RAMenuItemPathSetting : RAMenuItemGeneralSetting<RAMenuItemBase> @end

/*********************************************/
/* RAMenuItemEnumSetting                     */
/* A menu item that displays and allows      */
/* a setting to be set from a list of        */
/* allowed choices.                          */
/*********************************************/
@interface RAMenuItemEnumSetting : RAMenuItemGeneralSetting<RAMenuItemBase> @end

/*********************************************/
/* RAMenuItemBindSetting                     */
/* A menu item that displays and allows      */
/* mapping of a keybinding.                  */
/*********************************************/
@interface RAMenuItemBindSetting : RAMenuItemGeneralSetting<RAMenuItemBase> @end

/*********************************************/
/* RAMainMenu                                */
/* Menu object that is displayed immediately */
/* after startup.                            */
/*********************************************/
@interface RAMainMenu : RAMenuBase
@property (nonatomic) NSString* core;
@end

@interface RADirectoryItem : NSObject<RAMenuItemBase>
@property (nonatomic) NSString* path;
@property (nonatomic) bool isDirectory;
@end

@interface RADirectoryList : RAMenuBase<UIActionSheetDelegate>
@property (nonatomic, weak) RADirectoryItem* selectedItem;

@property (nonatomic, copy) void (^chooseAction)(RADirectoryList* list, RADirectoryItem* item);
@property (nonatomic, copy) NSString* path;
@property (nonatomic, copy) NSString* extensions;

@property (nonatomic) bool allowBlank;
@property (nonatomic) bool forDirectory;

- (id)initWithPath:(NSString*)path extensions:(const char*)extensions action:(void (^)(RADirectoryList* list, RADirectoryItem* item))action;
- (void)browseTo:(NSString*)path;
@end

@interface RANumberFormatter : NSNumberFormatter<UITextFieldDelegate>

- (id)initWithSetting:(const rarch_setting_t*)setting;
@end

// Number formatter class for setting strings
@implementation RANumberFormatter
- (id)initWithSetting:(const rarch_setting_t*)setting
{
    if ((self = [super init]))
    {
        [self setAllowsFloats:(setting->type == ST_FLOAT)];
        
        if (setting->flags & SD_FLAG_HAS_RANGE)
        {
            [self setMinimum:BOXFLOAT(setting->min)];
            [self setMaximum:BOXFLOAT(setting->max)];
        }
    }
    
    return self;
}

- (BOOL)isPartialStringValid:(NSString*)partialString newEditingString:(NSString**)newString errorDescription:(NSString**)error
{
    unsigned i;
    bool hasDot = false;
    
    if (partialString.length)
        for (i = 0; i < partialString.length; i ++)
        {
            unichar ch = [partialString characterAtIndex:i];
            
            if (i == 0 && (!self.minimum || self.minimum.intValue < 0) && ch == '-')
                continue;
            else if (self.allowsFloats && !hasDot && ch == '.')
                hasDot = true;
            else if (!isdigit(ch))
                return NO;
        }
    
    return YES;
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string
{
    NSString* text = (NSString*)[[textField text] stringByReplacingCharactersInRange:range withString:string];
    return [self isPartialStringValid:text newEditingString:nil errorDescription:nil];
}

@end

/*********************************************/
/* RunActionSheet                            */
/* Creates and displays a UIActionSheet with */
/* buttons pulled from a RetroArch           */
/* string_list structure.                    */
/*********************************************/
static const void* const associated_delegate_key = &associated_delegate_key;

typedef void (^RAActionSheetCallback)(UIActionSheet*, NSInteger);

@interface RARunActionSheetDelegate : NSObject<UIActionSheetDelegate>
@property (nonatomic, copy) RAActionSheetCallback callbackBlock;
@end

@implementation RARunActionSheetDelegate

- (id)initWithCallbackBlock:(RAActionSheetCallback)callback
{
   if ((self = [super init]))
      _callbackBlock = callback;
   return self;
}

- (void)actionSheet:(UIActionSheet *)actionSheet willDismissWithButtonIndex:(NSInteger)buttonIndex
{
   if (self.callbackBlock)
      self.callbackBlock(actionSheet, buttonIndex);
}

@end

static void RunActionSheet(const char* title, const struct string_list* items, UIView* parent, RAActionSheetCallback callback)
{
   size_t i;
   RARunActionSheetDelegate* delegate = [[RARunActionSheetDelegate alloc] initWithCallbackBlock:callback];
   UIActionSheet* actionSheet = [UIActionSheet new];

   actionSheet.title = BOXSTRING(title);
   actionSheet.delegate = delegate;
   
   for (i = 0; i < items->size; i ++)
      [actionSheet addButtonWithTitle:BOXSTRING(items->elems[i].data)];
   
   actionSheet.cancelButtonIndex = [actionSheet addButtonWithTitle:BOXSTRING("Cancel")];
   
   objc_setAssociatedObject(actionSheet, associated_delegate_key, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
   
   [actionSheet showInView:parent];
}


/*********************************************/
/* RAMenuBase                                */
/* A menu class that displays RAMenuItemBase */
/* objects.                                  */
/*********************************************/
@implementation RAMenuBase

- (id)initWithStyle:(UITableViewStyle)style
{
   if ((self = [super initWithStyle:style]))
      _sections = [NSMutableArray array];
   return self;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView
{
   return self.sections.count;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section
{
   if (self.hidesHeaders)
       return nil;
   return self.sections[section][0];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
   return [self.sections[section] count] - 1;
}

- (id)itemForIndexPath:(NSIndexPath*)indexPath
{
   return self.sections[indexPath.section][indexPath.row + 1];
}

- (UITableViewCell*)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
   return [[self itemForIndexPath:indexPath] cellForTableView:tableView];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
   [[self itemForIndexPath:indexPath] wasSelectedOnTableView:tableView ofController:self];
}

- (void)willReloadData
{
   
}

- (void)reloadData
{
   [self willReloadData];
   [[self tableView] reloadData];
}

@end

/*********************************************/
/* RAMenuItemBasic                           */
/* A simple menu item that displays a text   */
/* description and calls a block object when */
/* selected.                                 */
/*********************************************/
@implementation RAMenuItemBasic
@synthesize description;
@synthesize userdata;
@synthesize action;
@synthesize detail;

+ (RAMenuItemBasic*)itemWithDescription:(NSString*)description action:(void (^)())action
{
   return [self itemWithDescription:description action:action detail:Nil];
}

+ (RAMenuItemBasic*)itemWithDescription:(NSString*)description action:(void (^)())action detail:(NSString* (^)())detail
{
   return [self itemWithDescription:description association:nil action:action detail:detail];
}

+ (RAMenuItemBasic*)itemWithDescription:(NSString*)description association:(id)userdata action:(void (^)())action detail:(NSString* (^)())detail
{
   RAMenuItemBasic* item = [RAMenuItemBasic new];
   item.description = description;
   item.userdata = userdata;
   item.action = action;
   item.detail = detail;
   return item;
}

- (UITableViewCell*)cellForTableView:(UITableView*)tableView
{
   static NSString* const cell_id = @"text";
   
   UITableViewCell* result = [tableView dequeueReusableCellWithIdentifier:cell_id];
   if (!result)
      result = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cell_id];
   
   result.selectionStyle = UITableViewCellSelectionStyleNone;
   result.textLabel.text = self.description;
   result.detailTextLabel.text = self.detail ? self.detail(self.userdata) : nil;
   return result;
}

- (void)wasSelectedOnTableView:(UITableView*)tableView ofController:(UIViewController*)controller
{
   if (self.action)
      self.action(self.userdata);
}

@end

/*********************************************/
/* RAMenuItemGeneralSetting                  */
/* A simple menu item that displays the      */
/* state, and allows editing, of a string or */
/* numeric setting.                          */
/*********************************************/
@interface RAMenuItemGeneralSetting() <UIAlertViewDelegate>
@property (nonatomic) RANumberFormatter* formatter;
@end

@implementation RAMenuItemGeneralSetting

- (id)initWithSetting:(rarch_setting_t*)setting action:(void (^)())action
{
  if ((self = [super init])) {
    _setting = setting;
    _action = action;
  }
  return self;
}

- (UITableViewCell*)cellForTableView:(UITableView*)tableView
{
   char buffer[PATH_MAX_LENGTH];
   UITableViewCell* result;
   static NSString* const cell_id = @"string_setting";

   self.parentTable = tableView;

   result = [tableView dequeueReusableCellWithIdentifier:cell_id];
   if (!result)
   {
      result = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cell_id];
      result.selectionStyle = UITableViewCellSelectionStyleNone;
   }
   
   [self attachDefaultingGestureTo:result];

   result.textLabel.text = BOXSTRING("<Uninitialized>");

   if (self.setting)
   {
      if (self.setting->short_description)
         result.textLabel.text = BOXSTRING(self.setting->short_description);

      setting_get_string_representation(self.setting, buffer, sizeof(buffer));
      if (buffer[0] == '\0')
         strlcpy(buffer, "<default>", sizeof(buffer));

      result.detailTextLabel.text = BOXSTRING(buffer);

      if (self.setting->type == ST_PATH)
         result.detailTextLabel.text = [result.detailTextLabel.text lastPathComponent];
   }
   return result;
}

- (void)wasSelectedOnTableView:(UITableView*)tableView ofController:(UIViewController*)controller
{
   char buffer[PATH_MAX_LENGTH];
   NSString *desc = BOXSTRING("N/A");
   UIAlertView *alertView;
   UITextField *field;
    
   if (self.setting && self.setting->short_description)
      desc = BOXSTRING(self.setting->short_description);
    
   alertView = [[UIAlertView alloc] initWithTitle:BOXSTRING("Enter new value") message:desc delegate:self cancelButtonTitle:BOXSTRING("Cancel") otherButtonTitles:BOXSTRING("OK"), nil];
   alertView.alertViewStyle = UIAlertViewStylePlainTextInput;

   field = [alertView textFieldAtIndex:0];
   
   field.delegate = self.formatter;

   setting_get_string_representation(self.setting, buffer, sizeof(buffer));
   if (buffer[0] == '\0')
      strlcpy(buffer, "N/A", sizeof(buffer));

   field.placeholder = BOXSTRING(buffer);

   [alertView show];
}

- (void)alertView:(UIAlertView*)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
   NSString* text = (NSString*)[alertView textFieldAtIndex:0].text;

   if (buttonIndex != alertView.firstOtherButtonIndex)
       return;
    if (!text.length)
        return;
    
    setting_set_with_string_representation(self.setting, [text UTF8String]);
    [self.parentTable reloadData];
}

- (void)attachDefaultingGestureTo:(UIView*)view
{
   for (UIGestureRecognizer* i in view.gestureRecognizers)
      [view removeGestureRecognizer:i];
   [view addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                    action:@selector(resetValue:)]];
}

- (void)resetValue:(UIGestureRecognizer*)gesture
{
   struct string_list* items;
   RAMenuItemGeneralSetting __weak* weakSelf;
   
   if (gesture.state != UIGestureRecognizerStateBegan)
      return;
   
   weakSelf = self;
   items = (struct string_list*)string_split("OK", "|");
   
   RunActionSheet("Really Reset Value?", items, self.parentTable,
         ^(UIActionSheet* actionSheet, NSInteger buttonIndex)
         {
            if (buttonIndex != actionSheet.cancelButtonIndex)
               setting_reset_setting(self.setting);
            [weakSelf.parentTable reloadData];
         });
   
   string_list_free(items);
}

@end

/*********************************************/
/* RAMenuItemBooleanSetting                  */
/* A simple menu item that displays the      */
/* state, and allows editing, of a boolean   */
/* setting.                                  */
/*********************************************/
@implementation RAMenuItemBooleanSetting

- (id)initWithSetting:(rarch_setting_t*)setting action:(void (^)())action
{
  if ((self = [super init]))
  {
    _setting = setting;
    _action = action;
  }
   return self;
}

- (UITableViewCell*)cellForTableView:(UITableView*)tableView
{
   static NSString* const cell_id = @"boolean_setting";
   
   UITableViewCell* result = (UITableViewCell*)[tableView dequeueReusableCellWithIdentifier:cell_id];
   
   if (!result)
   {
      result = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cell_id];
      result.selectionStyle = UITableViewCellSelectionStyleNone;
      result.accessoryView = [UISwitch new];
   }
   
   result.textLabel.text = BOXSTRING(self.setting->short_description);
   [(id)result.accessoryView removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
   [(id)result.accessoryView addTarget:self action:@selector(handleBooleanSwitch:) forControlEvents:UIControlEventValueChanged];
   
   if (self.setting)
      [(id)result.accessoryView setOn:*self.setting->value.boolean];
   return result;
}

- (void)handleBooleanSwitch:(UISwitch*)swt
{
  if (self.setting)
    *self.setting->value.boolean = swt.on ? true : false;
  if (self.action)
    self.action();
}

- (void)wasSelectedOnTableView:(UITableView*)tableView ofController:(UIViewController*)controller
{
}

@end

/*********************************************/
/* RAMenuItemPathSetting                     */
/* A menu item that displays and allows      */
/* browsing for a path setting.              */
/*********************************************/
@interface RAMenuItemPathSetting() @end
@implementation RAMenuItemPathSetting

- (void)wasSelectedOnTableView:(UITableView*)tableView ofController:(UIViewController*)controller
{
   NSString *path;
   RADirectoryList* list;
   RAMenuItemPathSetting __weak* weakSelf = self;

   if (self.setting && self.setting->type == ST_ACTION &&
       self.setting->flags & SD_FLAG_BROWSER_ACTION &&
       self.setting->action_toggle &&
       self.setting->change_handler )
     self.setting->action_toggle( self.setting, MENU_ACTION_RIGHT, false);

   path = BOXSTRING(self.setting->value.string);
   
   if ( self.setting->type == ST_PATH )
     path = [path stringByDeletingLastPathComponent];
      
   list = [[RADirectoryList alloc] initWithPath:path extensions:self.setting->values action:
      ^(RADirectoryList* list, RADirectoryItem* item)
      {
        const char *newval = "";
        if (item)
        {
          if (list.forDirectory && !item.isDirectory)
            return;

          newval = [item.path UTF8String];
        }
        else
        {
          if (!list.allowBlank)
            return;
        }

        setting_set_with_string_representation(weakSelf.setting, newval);
        [[list navigationController] popViewControllerAnimated:YES];

        weakSelf.action();
         
        [weakSelf.parentTable reloadData];
      }];

   list.allowBlank = (self.setting->flags & SD_FLAG_ALLOW_EMPTY);
   list.forDirectory = (self.setting->flags & SD_FLAG_PATH_DIR);
   
   [controller.navigationController pushViewController:list animated:YES];
}

@end

/*********************************************/
/* RAMenuItemEnumSetting                     */
/* A menu item that displays and allows      */
/* a setting to be set from a list of        */
/* allowed choices.                          */
/*********************************************/
@implementation RAMenuItemEnumSetting

- (void)wasSelectedOnTableView:(UITableView*)tableView ofController:(UIViewController*)controller
{
   struct string_list* items;
   RAMenuItemEnumSetting __weak* weakSelf = self;
   
   items = (struct string_list*)string_split(self.setting->values, "|");
   RunActionSheet(self.setting->short_description, items, self.parentTable,
      ^(UIActionSheet* actionSheet, NSInteger buttonIndex)
      {
         if (buttonIndex == actionSheet.cancelButtonIndex)
            return;
         
         setting_set_with_string_representation(self.setting, [[actionSheet buttonTitleAtIndex:buttonIndex] UTF8String]);
         [weakSelf.parentTable reloadData];
      });
   string_list_free(items);
}

@end


/*********************************************/
/* RAMenuItemBindSetting                     */
/* A menu item that displays and allows      */
/* mapping of a keybinding.                  */
/*********************************************/
@interface RAMenuItemBindSetting() <UIAlertViewDelegate>
@property (nonatomic) NSTimer* bindTimer;
@property (nonatomic) UIAlertView* alert;
@end

@implementation RAMenuItemBindSetting

- (void)wasSelectedOnTableView:(UITableView *)tableView ofController:(UIViewController *)controller
{
   self.alert = [[UIAlertView alloc] initWithTitle:BOXSTRING("RetroArch")
                                     message:BOXSTRING(self.setting->short_description)
                                     delegate:self
                                     cancelButtonTitle:BOXSTRING("Cancel")
                                     otherButtonTitles:BOXSTRING("Clear Keyboard"), BOXSTRING("Clear Joystick"), BOXSTRING("Clear Axis"), nil];

   [self.alert show];
   
   [self.parentTable reloadData];
   
   self.bindTimer = [NSTimer scheduledTimerWithTimeInterval:.1f target:self selector:@selector(checkBind:)
                             userInfo:nil repeats:YES];
}

- (void)finishWithClickedButton:(bool)clicked
{
   if (!clicked)
      [self.alert dismissWithClickedButtonIndex:self.alert.cancelButtonIndex animated:YES];
   self.alert = nil;

   [self.parentTable reloadData];

   [self.bindTimer invalidate];
   self.bindTimer = nil;
   
   cocoa_input_reset_icade_buttons();
}

- (void)alertView:(UIAlertView*)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
   if (buttonIndex == alertView.firstOtherButtonIndex)
      BINDFOR(*self.setting).key = RETROK_UNKNOWN;
   else if(buttonIndex == alertView.firstOtherButtonIndex + 1)
      BINDFOR(*self.setting).joykey = NO_BTN;
   else if(buttonIndex == alertView.firstOtherButtonIndex + 2)
      BINDFOR(*self.setting).joyaxis = AXIS_NONE;
   
   [self finishWithClickedButton:true];
}

- (void)checkBind:(NSTimer*)send
{
   int32_t value = 0;
   int32_t idx = 0;

   if (self.setting->index)
      idx = self.setting->index - 1;

   if ((value = cocoa_input_find_any_key()))
      BINDFOR(*self.setting).key = input_keymaps_translate_keysym_to_rk(value);
   else if ((value = cocoa_input_find_any_button(idx)) >= 0)
      BINDFOR(*self.setting).joykey = value;
   else if ((value = cocoa_input_find_any_axis(idx)))
      BINDFOR(*self.setting).joyaxis = (value > 0) ? AXIS_POS(value - 1) : AXIS_NEG(abs(value) - 1);
   else
      return;

   [self finishWithClickedButton:false];
}

@end


/*********************************************/
/* RAMainMenu                                */
/* Menu object that is displayed immediately */
/* after startup.                            */
/*********************************************/
@implementation RAMainMenu

- (id)init
{
   if ((self = [super initWithStyle:UITableViewStylePlain]))
      self.title = BOXSTRING("RetroArch");
   return self;
}

- (void)viewWillAppear:(BOOL)animated
{
   [self reloadData];
}

- (void)willReloadData
{
   size_t i, end;
   char title[256], title_msg[256];
   NSMutableArray *everything;
   RAMainMenu* __weak weakSelf;
   const char *dir           = NULL;
   const char *label         = NULL;
   unsigned menu_type        = 0;
   menu_handle_t *menu       = menu_driver_get_ptr();
   
   if (!menu)
      return;
   
   everything = [NSMutableArray array];

   get_core_title(title_msg, sizeof(title_msg));
   self.title = BOXSTRING(title_msg);

   menu_list_get_last_stack(menu->menu_list, &dir, &label, &menu_type);
   get_title(label, dir, menu_type, title, sizeof(title));
   [everything addObject:BOXSTRING(title)];
  
   end = menu_list_get_size(menu->menu_list); 
   for (i = menu->begin; i < end; i++) {
     [everything addObject:[self make_menu_item_for_entry: i]];     
   }
   
   self.sections = [NSMutableArray array];
   [self.sections addObject:everything];

   weakSelf = self;
   if (menu_list_get_stack_size(menu->menu_list) > 1)
     [self set_leftbutton:BOXSTRING("Back")
                   target:weakSelf
                   action:@selector(menuBack)];
   else
     [self set_leftbutton:BOXSTRING("Resume")
                   target:[RetroArch_iOS get]
                   action:@selector(showGameView)];

   if ( menu->message_contents[0] != '\0' )
     apple_display_alert(menu->message_contents, NULL);
}

- (void) set_leftbutton:(NSString *)title target:(id)target action:(SEL)action
{
  self.navigationItem.leftBarButtonItem =
    [[UIBarButtonItem alloc]
           initWithTitle:title
                   style:UIBarButtonItemStyleBordered
                  target:target
                  action:action];
}

// JM: This could go down into RA
void get_core_title(char *title_msg, size_t title_msg_len)
{
   global_t *global          = global_get_ptr();
   const char *core_name     = global->menu.info.library_name;
   const char *core_version  = global->menu.info.library_version;
   
   if (!core_name)
     core_name = global->system.info.library_name;
   if (!core_name)
     core_name = "No Core";

   if (!core_version)
     core_version = global->system.info.library_version;
   if (!core_version)
     core_version = "";

   snprintf(title_msg, title_msg_len, "%s - %s %s", PACKAGE_VERSION,
            core_name, core_version);
}

- (NSObject<RAMenuItemBase>*)make_menu_item_for_entry: (uint) i
{
  menu_handle_t *menu       = menu_driver_get_ptr();
  RAMainMenu* __weak weakSelf;
  rarch_setting_t *setting;
  char type_str[PATH_MAX_LENGTH], path_buf[PATH_MAX_LENGTH];
  menu_file_list_cbs_t *cbs = NULL;
  const char *path = NULL, *entry_label = NULL;
  unsigned type = 0, w = 0;
  const char *dir           = NULL;
  const char *label         = NULL;
  unsigned menu_type        = 0;

  weakSelf = self;
  menu_list_get_last_stack(menu->menu_list, &dir, &label, &menu_type);

  menu_list_get_at_offset(menu->menu_list->selection_buf, i, &path,
                          &entry_label, &type);

  // JM: Ideally, this would be simpler because RA would provide a
  // function that takes "i" and returns either Path, DirPath, Bool,
  // Bind, Enum, Number, String, Action. [Sub-menus would be action,
  // because it causes an effect]

  setting =
    (rarch_setting_t*)setting_find_setting
    (menu->list_settings,
     menu->menu_list->selection_buf->list[i].label);

  if (setting && setting->type == ST_ACTION &&
      setting->flags & SD_FLAG_BROWSER_ACTION &&
      setting->action_toggle &&
      setting->change_handler) {
    return [[RAMenuItemPathSetting alloc]
                       initWithSetting:setting
                                action:^{}];
  } else if (setting && setting->type == ST_BOOL ) {
    return [[RAMenuItemBooleanSetting alloc]
               initWithSetting:setting
                        action:^{[weakSelf menuSelect: i];}];
  } else if (setting && ST_PATH <= setting->type && setting->type <= ST_DIR) {
    return [[RAMenuItemPathSetting alloc]
               initWithSetting:setting
                        action:^{[weakSelf menuSelect: i];}];
  } else if (setting && setting->type == ST_BIND ) {
    return [[RAMenuItemBindSetting alloc]
               initWithSetting:setting
                        action:^{[weakSelf menuSelect: i];}];
  } else if (setting && setting->type == ST_STRING && setting->values ) {
    return [[RAMenuItemEnumSetting alloc]
             initWithSetting:setting
                      action:^{[weakSelf menuSelect: i];}];
  } else if (setting && ST_INT <= setting->type && setting->type <= ST_HEX) {
    RAMenuItemGeneralSetting* item =
      [[RAMenuItemGeneralSetting alloc]
        initWithSetting:setting
                 action:^{[weakSelf menuSelect: i];}];
   
    if (setting->type == ST_INT  ||
        setting->type == ST_UINT ||
        setting->type == ST_FLOAT)
      item.formatter = [[RANumberFormatter alloc] initWithSetting:item.setting];
   
    return item;
  } else { // This is for ST_GROUP/etc
    cbs = (menu_file_list_cbs_t*)
      menu_list_get_actiondata_at_offset(menu->menu_list->selection_buf, i);
  
    if (cbs && cbs->action_get_representation) {
      cbs->action_get_representation
        (menu->menu_list->selection_buf,
         &w, type, i, label,
         type_str, sizeof(type_str), 
         entry_label, path,
         path_buf, sizeof(path_buf));
    }
    
    return [RAMenuItemBasic
                       itemWithDescription:BOXSTRING(path_buf)
                                    action:^{[weakSelf menuSelect: i];}];
  }
}

- (void)menuSelect: (uint) i
{
  if (menu_select_entry(i)) {
    [self menuRefresh];
    [self reloadData];
  }
}

// JM: This could be moved down to RA
uint menu_select_entry(uint i) {
  menu_handle_t *menu       = menu_driver_get_ptr();
  rarch_setting_t *setting;
  menu_file_list_cbs_t *cbs = NULL;
  const char *path = NULL, *entry_label = NULL;
  unsigned type = 0;
  const char *dir           = NULL;
  const char *label         = NULL;
  unsigned menu_type        = 0;

  menu_list_get_last_stack(menu->menu_list, &dir, &label, &menu_type);

  menu_list_get_at_offset(menu->menu_list->selection_buf, i, &path,
                          &entry_label, &type);

  setting =
    (rarch_setting_t*)setting_find_setting
    (menu->list_settings,
     menu->menu_list->selection_buf->list[i].label);

  cbs = (menu_file_list_cbs_t*)
    menu_list_get_actiondata_at_offset(menu->menu_list->selection_buf, i);
  
  if (setting && setting->type == ST_ACTION &&
      setting->flags & SD_FLAG_BROWSER_ACTION &&
      setting->action_toggle &&
      setting->change_handler) {
    return FALSE;
  } else if (setting && ST_ACTION < setting->type && setting->type < ST_GROUP) {
    menu->navigation.selection_ptr = i;
    if (cbs && cbs->action_ok)
      cbs->action_ok(path, entry_label, type, i);
    
    return FALSE;
  } else {
    menu->navigation.selection_ptr = i;
    if (cbs && cbs->action_ok) {
      cbs->action_ok(path, entry_label, type, i);
    } else {
      if (cbs && cbs->action_start)
        cbs->action_start(type, entry_label, MENU_ACTION_START);
      if (cbs && cbs->action_toggle)
        cbs->action_toggle(type, entry_label, MENU_ACTION_RIGHT, true);
      menu_list_push_stack(menu->menu_list, "",
                           "info_screen", 0, i);
    }
    return TRUE;
  }
}

- (void)menuRefresh
{
  menu_handle_t *menu = menu_driver_get_ptr();
  if (!menu)
     return;
  if (!menu->need_refresh)
     return;
   
    menu_entries_deferred_push(menu->menu_list->selection_buf,
                               menu->menu_list->menu_stack);
    menu->need_refresh = false;
}

- (void)menuBack
{
   menu_handle_t *menu = menu_driver_get_ptr();
   if (!menu)
      return;
   
  menu_apply_deferred_settings();
  menu_list_pop_stack(menu->menu_list);
  [self menuRefresh];
  [self reloadData];
}

@end
