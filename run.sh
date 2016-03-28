gnome-terminal -e "./startclients.sh" &
make
erl -sname myserver@localhost -setcookie abc -run server
