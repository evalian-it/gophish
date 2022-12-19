#!/bin/sh

#Ask for domain, maildomain, and mailrelay variables, read back
read -p 'Domain: ' DOMAIN
read -p 'Mail domain: ' MAILDOMAIN
read -p 'Mail relay: ' MAILRELAY
read -p 'Mail user (lowercase): ' MAILUSER
read -p 'DKIM selector: ' SELECTOR

echo -e "\r\nDomain: $DOMAIN\r\nMail domain: $MAILDOMAIN\r\nMail relay: $MAILRELAY\r\nMail user: $MAILUSER"

#Postfix setup
DEBIAN_FRONTEND=noninteractive apt-get install postfix -y
sed -i 's/mail.//g' /etc/mailname
sed -i "41s/$/, $DOMAIN/" /etc/postfix/main.cf
postconf -e 'home_mailbox= Maildir/'
postconf -e 'virtual_alias_maps= hash:/etc/postfix/virtual'
echo -e "$MAILUSER@$DOMAIN	$MAILUSER" >> /etc/postfix/virtual
postmap /etc/postfix/virtual
postconf -e 'inet_protocols= ipv4'
postconf -e "mynetworks= 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 $MAILRELAY/32"
echo 'export MAIL=~/Maildir' | sudo tee -a /etc/bash.bashrc | sudo tee -a /etc/profile.d/mail.sh
source /etc/profile.d/mail.sh

#s-nail setup
apt-get install s-nail -y
echo -e "set emptystart\r\nset folder=Maildir\r\nset record=+sent" >> /etc/s-nail.rc

#root mailbox init, mail user setup and mailbox init
echo 'init' | s-nail -s 'init' -Snorecord $MAILUSER
adduser $MAILUSER
echo 'init' | s-nail -s 'init' -Snorecord $MAILUSER

#OpenDKIM setup
apt-get install opendkim opendkim-tools -y
usermod -a -G opendkim postfix
echo -e "AutoRestart	yes\r\nAutoRestartRate	10/1M\r\nBackground	yes\r\nDNSTimeout	5\r\nSignatureAlgorithm	rsa-sha256\r\nMode	sv\r\nSubDomains	no\r\nLogWhy	yes\r\nKeyTable	refile:/etc/opendkim/key.table\r\nSigningTable	refile:/etc/opendkim/signing.table\r\nExternalIgnoreList	/etc/opendkim/trusted.hosts\r\nInternalHosts	/etc/opendkim/trusted.hosts" >> /etc/opendkim.conf
mkdir -p /etc/opendkim/keys
chown -R opendkim:opendkim /etc/opendkim
chmod go-rw /etc/opendkim/keys
echo -e "*@$DOMAIN	$SELECTOR._domainkey.$DOMAIN\r\n*@*.$DOMAIN	$SELECTOR._domainkey.$DOMAIN" >> /etc/opendkim/signing.table
echo -e "$SELECTOR._domainkey.$DOMAIN	$DOMAIN:$SELECTOR:/etc/opendkim/keys/$DOMAIN/$SELECTOR.private" >> /etc/opendkim/key.table
echo -e "127.0.0.1\r\nlocalhost\r\n$MAILRELAY\r\n\r\n.$DOMAIN" >> /etc/opendkim/trusted.hosts
mkdir /etc/opendkim/keys/$DOMAIN
opendkim-genkey -b 2048 -d $DOMAIN -D /etc/opendkim/keys/$DOMAIN -s $SELECTOR -v
chown opendkim:opendkim /etc/opendkim/keys/$DOMAIN/$SELECTOR.private
chmod 600 /etc/opendkim/keys/$DOMAIN/$SELECTOR.private

#Read DKIM record, pause to allow user to post records, test dkim, pause to read opendkim-testkey output
cat /etc/opendkim/keys/$DOMAIN/$SELECTOR.txt
echo -e "\r\nPlease publish the following DNS records:\r\nroot A\r\nmail A\r\nMX\r\nDKIM\r\nSPF\r\nDMARC\r\n\r\n"
read -p "Press any key to continue... " -n1 -s
opendkim-testkey -d $DOMAIN -s $SELECTOR -vvv
read -p "Press any key to continue... " -n1 -s

#Continue OpenDKIM setup
mkdir /var/spool/postfix/opendkim
chown opendkim:postfix /var/spool/postfix/opendkim
sed -i 's/Socket			local:\/run\/opendkim\/opendkim.sock/Socket			local:\/var\/spool\/postfix\/opendkim\/opendkim.sock/g' /etc/opendkim.conf
sed -i 's/SOCKET=local:$RUNDIR\/opendkim.sock/SOCKET="local:\/var\/spool\/postfix\/opendkim\/opendkim.sock"/g' /etc/default/opendkim
echo -e "milter_default_action = accept\r\nmilter_protocol = 6\r\nsmtpd_milters = local:opendkim/opendkim.sock\r\nnon_smtpd_milters = $smtpd_milters" >> /etc/postfix/main.cf

#Courier-IMAP setup
DEBIAN_FRONTEND=noninteractive apt-get install courier-imap -y
imapd start && imapd-ssl start
service courier-authdaemon start
systemctl enable courier-authdaemon

#Gophish setup
mkdir /opt/gophish
cd /opt/gophish
wget -O /opt/gophish/gophish-v0.7.1-linux-64bit.zip https://github.com/gophish/gophish/releases/download/0.7.1/gophish-v0.7.1-linux-64bit.zip
apt-get install unzip
unzip /opt/gophish/gophish-v0.7.1-linux-64bit.zip -d /opt/gophish
chmod +x gophish

#Setup Gophish as service
wget -O /lib/systemd/system/gophish.service https://raw.githubusercontent.com/evalian-it/gophish/main/gophish.service
wget -O /root/gophish.sh https://raw.githubusercontent.com/evalian-it/gophish/main/gophish.sh
chmod +x /root/gophish.sh
systemctl daemon-reload
systemctl enable gophish.service

#LetsEncrypt Certbot setup
apt-get install certbot -y
certbot certonly -d $DOMAIN -d $MAILDOMAIN --manual --preferred-challenges dns

#Postfix, Courier-IMAP, and Gophish SSL setup
sed -i 's/127.0.0.1/0.0.0.0/g' config.json
sed -i 's/80/443/g' config.json
sed -i 's/false/true/g' config.json
sed -i "s/gophish_admin.crt/\/etc\/letsencrypt\/live\/$DOMAIN\/fullchain.pem/g" config.json
sed -i "s/gophish_admin.key/\/etc\/letsencrypt\/live\/$DOMAIN\/privkey.pem/g" config.json
sed -i "s/example.crt/\/etc\/letsencrypt\/live\/$DOMAIN\/fullchain.pem/g" config.json
sed -i "s/example.key/\/etc\/letsencrypt\/live\/$DOMAIN\/privkey.pem/g" config.json
sed -i "s/smtpd_tls_cert_file=\/etc\/ssl\/certs\/ssl-cert-snakeoil.pem/smtpd_tls_cert_file=\/etc\/letsencrypt\/live\/$DOMAIN\/fullchain.pem/g" /etc/postfix/main.cf
sed -i "s/smtpd_tls_key_file=\/etc\/ssl\/private\/ssl-cert-snakeoil.key/smtpd_tls_key_file=\/etc\/letsencrypt\/live\/$DOMAIN\/privkey.pem/g" /etc/postfix/main.cf
sed -i "s/TLS_CERTFILE=\/etc\/courier\/imapd.pem/TLS_CERTFILE=\/etc\/letsencrypt\/live\/$DOMAIN\/fullchain.pem/g" /etc/courier/imapd-ssl
sed -i "s/#TLS_PRIVATE_KEYFILE=\/etc\/courier\/imapd_private_key.pem/TLS_PRIVATE_KEYFILE=\/etc\/letsencrypt\/live\/$DOMAIN\/privkey.pem/g" /etc/courier/imapd-ssl
sed -i 's/IMAP_TLS_REQUIRED=0/IMAP_TLS_REQUIRED=1/g' /etc/courier/imapd-ssl

#ufw setup
sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw
ufw allow 22/tcp && ufw allow 25/tcp && ufw allow 443/tcp && ufw allow 993/tcp && ufw allow 3333/tcp && ufw enable

#Ask user to reboot
echo -e "\r\n\r\nPlease reboot the system\r\n"
