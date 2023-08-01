cd /srv/
semanage fcontext -a -t httpd_sys_content_t www
restorecon -R -v www/
semanage fcontext -a -t httpd_sys_script_exec_t /srv/www/radioactivity/radioactivity_admin.pl
restorecon /srv/www/radioactivity/radioactivity_admin.pl 

