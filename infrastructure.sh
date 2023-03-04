#!/bin/bash

# Set AWS region and VPC CIDR block
region="us-west-2"
vpc_cidr="10.0.0.0/16"

# Create VPC
vpc_id=$(aws ec2 create-vpc \
	--cidr-block $vpc_cidr \
	--query 'Vpc.VpcId' \
	--output text \
	--region $region)
echo "VPC ID $vpc_id"

# Create public subnet for EC2 instance
public_cidr="10.0.1.0/24"
public_subnet_id=$(aws ec2 create-subnet \
	--vpc-id $vpc_id \
	--cidr-block $public_cidr \
	--availability-zone ${region}a \
	--query 'Subnet.SubnetId' \
	--output text \
	--region $region)
echo "Subnet ID (public ec2) $public_subnet_id"

# Create private subnets for RDS database
private_subnet_cidr1="10.0.2.0/24"
private_subnet_cidr2="10.0.3.0/24"
private_subnet_id1=$(aws ec2 create-subnet \
	--vpc-id $vpc_id \
	--cidr-block $private_subnet_cidr1 \
	--availability-zone ${region}b \
	--query 'Subnet.SubnetId' \
	--output text \
	--region $region)
echo "Subnet ID (private rds 1): $private_subnet_id1"
private_subnet_id2=$(aws ec2 create-subnet \
	--vpc-id $vpc_id \
	--cidr-block $private_subnet_cidr2 \
	--availability-zone ${region}c \
	--query 'Subnet.SubnetId' \
	--output text \
	--region $region)
echo "Subnet ID (private rds 2): $private_subnet_id2"

# Create Internet Gateway and attach to VPC
gateway_id=$(aws ec2 create-internet-gateway \
	--query 'InternetGateway.InternetGatewayId' \
	--output text \
	--region $region)
echo "Internet Gateway Id: $gateway_id"
aws ec2 attach-internet-gateway \
	--internet-gateway-id $gateway_id \
	--vpc-id $vpc_id \
	--region $region

# Create Route Table and add routes
route_table_id=$(aws ec2 create-route-table \
	--vpc-id $vpc_id \
	--query 'RouteTable.RouteTableId' \
	--output text \
	--region $region)
echo "Route Table Id: $route_table_id"
aws ec2 create-route \
	--route-table-id $route_table_id \
	--destination-cidr-block 0.0.0.0/0 \
	--gateway-id $gateway_id \
	--region $region
aws ec2 associate-route-table \
	--route-table-id $route_table_id \
	--subnet-id $public_subnet_id \
	--region $region

# Create security groups
ec2_sg_id=$(aws ec2 create-security-group \
	--group-name ec2-sg \
	--description "Security group for EC2 instance" \
	--vpc-id $vpc_id \
	--query 'GroupId' \
	--output text \
	--region $region)
echo "Security Group ID (ec2): $ec2_sg_id"
aws ec2 authorize-security-group-ingress \
	--group-id $ec2_sg_id \
	--protocol tcp \
	--port 22 \
	--cidr 0.0.0.0/0 \
	--region $region
aws ec2 authorize-security-group-ingress \
	--group-id $ec2_sg_id \
	--protocol tcp \
	--port 80 \
	--cidr 0.0.0.0/0 \
	--region $region

rds_sg_id=$(aws ec2 create-security-group \
	--group-name rds-sg \
	--description "Security group for RDS database" \
	--vpc-id $vpc_id \
	--query 'GroupId' \
	--output text \
	--region $region)
echo "Security Group ID (rds): $rds_sg_id"
aws ec2 authorize-security-group-ingress \
	--group-id $rds_sg_id \
	--protocol tcp \
	--port 3306 \
	--cidr $vpc_cidr \
	--region $region

# Create subnet group for RDS instance
subnet_group_name="assignment2-subnet-group"
aws rds create-db-subnet-group \
	--db-subnet-group-name $subnet_group_name \
	--db-subnet-group-description "Subnet group for my RDS instance" \
	--subnet-ids $private_subnet_id1 $private_subnet_id2 \
	--region $region

# Create RDS instance
db_instance_identifier="assignment2-rds"
db_instance_class="db.t2.micro"
engine="mysql"
username="root"
password="24862486"
allocated_storage=20
storage_type="gp2"
aws rds create-db-instance \
	--db-instance-identifier $db_instance_identifier \
	--db-instance-class $db_instance_class \
	--engine $engine \
	--allocated-storage $allocated_storage \
	--db-subnet-group-name $subnet_group_name \
	--vpc-security-group-ids $rds_sg_id \
	--master-username $username \
	--master-user-password $password \
	--no-publicly-accessible \
	--storage-type $storage_type \
	--region $region

echo "Wait for Database to get created. This may take serveral minutes..."
aws rds wait \
    db-instance-available \
    --db-instance-identifier $db_instance_identifier

# Create Keypair
key_name="assignment2-keypair"
key_pair=$(aws ec2 create-key-pair \
	--key-name $key_name \
	--query 'KeyMaterial' \
	--output text \
	--region $region)
chmod 400 $key_name.pem
echo "$key_pair" > "${key_name}.pem"

# Create EC2 instance
instance_type="t2.micro"
ami_id="ami-0735c191cf914754d" # Ubuntu 22.04 LTS
aws ec2 run-instances \
	--image-id $ami_id \
	--count 1 \
	--instance-type $instance_type \
	--key-name $key_name \
	--subnet-id $public_subnet_id \
	--security-group-ids $ec2_sg_id \
	--associate-public-ip-address \
	--tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=assignment2-ec2}]' \
	--region $region

instance_id=$(echo $instance_info | --query 'InstanceId')

# wait for instance to reach "running" state and get a public IP address
aws ec2 wait instance-running --instance-ids $instance_id
public_ip=$(aws ec2 describe-instances --instance-ids $instance_id --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# show how to connect to ec2
echo "SSH Into Your EC2: ssh -i $.pem ubuntu@$public_ip"

echo "Describe Infrastructure:"
aws ec2 describe-vpcs
