resource "null_resource" "update_kubeconfig" {
  depends_on = [local.cluster_name]

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ap-northeast-2 --name devlink-eks"
  }
}