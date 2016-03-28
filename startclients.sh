sleep 1
echo DISPLAY $DISPLAY
erl -sname client_1@localhost -setcookie abc -run client
