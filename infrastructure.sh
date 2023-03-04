#!/bin/bash

# Set AWS region
region="us-west-2a"

# Create VPC
vpc_cidr="10.0.0.0/16"
vpc_tag=acit4640-vpc
vpc_id=$(
	aws ec2 create-vpc \
	--cidr-block $vpc_cidr \
	| yq '.Vpc.VpcId')
echo "vpc: $vpc_id"
aws ec2 create-tags --resources $vpc_id --tags Key=Name,Value=$vpc_tag

# Create public subnet for EC2 instance
public_cidr="10.0.1.0/24"
public_subnet_id=$(
  aws ec2 create-subnet \
  --cidr-block $public_cidr \
  --availability-zone $region \
  --vpc-id $vpc_id \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=rdc-public-ec2}]' \
  | yq '.Subnet.SubnetId'
)
echo "subnet id ec2: $public_subnet_id"
aws ec2 modify-subnet-attribute --subnet-id $public_subnet_id --map-public-ip-on-launch

# Create private subnets for RDS database
private_subnet_cidr1="10.0.2.0/24"
private_subnet_cidr2="10.0.3.0/24"
region2_private_subnet="us-west-2b"
private_subnet_id1=$(
  aws ec2 create-subnet \
  --cidr-block $private_subnet_cidr1 \
  --availability-zone $region \
  --vpc-id $vpc_id \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=rdc-private-rds1}]' \
  | yq '.Subnet.SubnetId'
)
echo "subnet id rds1: $private_subnet_id1"
pri_rds_2_subnet_id=$(
  aws ec2 create-subnet \
  --cidr-block $private_subnet_cidr2 \
  --availability-zone $region2_private_subnet \
  --vpc-id $vpc_id \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=rdc-private-rds2}]' \
  | yq '.Subnet.SubnetId'
)
echo "subnet id rds2: $pri_rds_2_subnet_id"

# Create Internet Gateway and attach to VPC
igw_id=$(aws ec2 create-internet-gateway \
    --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=acit4640-igw}]' \
    | yq '.InternetGateway.InternetGatewayId'
)
echo "igw id: $igw_id"
aws ec2 attach-internet-gateway \
    --internet-gateway-id $igw_id \
    --vpc-id $vpc_id

# Create Route Table and add routes
route_table_id=$(aws ec2 create-route-table \
  --vpc-id $vpc_id \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=acit4640-rt}]' \
  | yq '.RouteTable.RouteTableId'
)
echo "rt id: $route_table_id"
aws ec2 create-route \
  --route-table-id $route_table_id \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $igw_id
assoc_id=$(aws ec2 associate-route-table \
  --subnet-id $public_subnet_id \
  --route-table-id $route_table_id \
  | yq '.AssociationId'
)
echo "association id: $assoc_id"

# Create security groups
ec2_sg_id=$(aws ec2 create-security-group \
  --group-name ec2-sg \
  --description "security group for public ec2" \
  --vpc-id $vpc_id \
  | yq -r '.GroupId'
)
echo "sg ec2: $ec2_sg_id"
aws ec2 authorize-security-group-ingress \
  --group-id $ec2_sg_id \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress \
  --group-id $ec2_sg_id \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0

rds_sg_id=$(aws ec2 create-security-group \
  --group-name rds-sg \
  --description "Security group for MySQL access from within VPC" \
  --vpc-id $vpc_id \
  | yq -r '.GroupId'
)
echo "sg rds: $rds_sg_id"
aws ec2 authorize-security-group-ingress \
  --group-id $rds_sg_id \
  --protocol tcp \
  --port 3306 \
  --cidr $vpc_cidr

# Create Keypair
aws ec2 create-key-pair \
  --key-name $key_name \
  --key-type ed25519 \
  --query 'KeyMaterial' \
  --output text > $key_name.pem

chmod 600 $key_name.pem

# Create EC2 instance 
key_name="assignment2-keypair"
ami_id="ami-0735c191cf914754d"
instance_type="t2.micro"
instance_info=$(aws ec2 run-instances \
    --image-id $ami_id \
    --instance-type $instance_type \
    --subnet-id $public_subnet_id \
    --security-group-ids $ec2_sg_id \
    --key-name $key_name \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=acit4640-ec2}]' \
    --query 'Instances[0].{InstanceId:InstanceId, PublicIpAddress:PublicIpAddress}' \
    --output json
)

# Save EC2 instance   
instance_id=$(echo $instance_info | yq -r '.InstanceId')

# Wait for EC2 instance to finish
aws ec2 wait instance-running --instance-ids $instance_id
public_ip=$(aws ec2 describe-instances --instance-ids $instance_id --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# create subnet group
rds_sng="assignment2-subnet-group"
aws rds create-db-subnet-group \
    --db-subnet-group-name $rds_sng \
    --db-subnet-group-description "Subnet group for my RDS instance" \
    --subnet-ids $private_subnet_id1 $pri_rds_2_subnet_id \
    --region us-west-2

# Create the RDS database instance
db_instance_identifier="assignment2-rds"
db_instance_class="db.t3.micro"
db_username="root"
db_password="password"
db_engine="mysql"
db_engine_version="8.0.28"
db_storage_type="gp2"
db_allocated_storage="20"
database_result=$(aws rds create-db-instance \
  --db-instance-identifier $db_instance_identifier \
  --db-instance-class $db_instance_class \
  --engine $db_engine \
  --master-username $db_username \
  --master-user-password $db_password \
  --allocated-storage $db_allocated_storage \
  --engine-version $db_engine_version \
  --storage-type $db_storage_type \
  --no-publicly-accessible \
  --vpc-security-group-ids $rds_sg_id \
  --db-subnet-group-name $rds_sng
)

# Wait for RDS to finish
aws rds wait \
    db-instance-available \
    --db-instance-identifier $db_instance_identifier

copy_app=$( scp -o StrictHostKeyChecking=no -i ./$key_name.pem ./app.sh ubuntu@$public_ip:~/)

# Save the RDS endpoint
endpoint=$(aws rds describe-db-instances | yq ".DBInstances.[].Endpoint.Address") 

# Put the endpoint and domain (public ip) into a .env
cat > env.sh <<EOL
endpoint=$endpoint
DOMAIN=$public_ip
EOL

endpoint_to_ec2=$( scp -o StrictHostKeyChecking=no -i ./$key_name.pem ./env.sh ubuntu@$public_ip:~/)

echo "ssh -i $key_name.pem ubuntu@$public_ip"

aws ec2 describe-vpcs
