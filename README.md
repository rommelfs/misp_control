# misp_control
Control your MISP instances, create new users, lookup users on all instances, bulk modify a user on several instances


example usage: 

# add a user on a specific instance
`./add_user.sh -c <email_address>`

search a user across all instances
./bulk_modify_users.sh -s <email_address>

disable email alerts to user on all instances
./bulk_modify_users.sh -e <email_address> 

disable user on all instances
./bulk_modify_users.sh -x <email_address>
