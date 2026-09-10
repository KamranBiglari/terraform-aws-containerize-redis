for i in {0..10}
do
  terraform init
  rm -rf .terraform/modules/redis_reporting_bank365 modules.json .terraform.lock.hcl
  sleep 15
done